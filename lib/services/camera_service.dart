import 'dart:async';
import 'dart:ui' show Offset;
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'jpeg_encoder.dart';
import 'h264_encoder_channel.dart';

/// Owns the camera hardware: preview, live frame capture, zoom, flip and torch.
///
/// Frames from [CameraController.startImageStream] are handed to a background
/// [JpegEncoder] isolate (so the UI/preview thread is never blocked) and the
/// resulting JPEG is pushed to [onJpegFrame]. Strict single-frame-in-flight
/// backpressure keeps the stream realtime instead of building up delay.
class CameraService extends ChangeNotifier {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;

  bool _streaming = false;
  bool _frameInFlight = false; // an encode is currently running
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  JpegEncoder _encoder = JpegEncoder();
  bool _encoderReady = false;

  // ── H.264 mode ───────────────────────────────────────────────────────────────
  // When the desktop negotiates 'h264', frames are sent to the native hardware
  // encoder instead of the Dart JPEG isolate. The connection layer wires
  // [onH264Au] to frame each access unit for the wire.
  final H264EncoderChannel _h264 = H264EncoderChannel();
  bool _h264Mode = false;
  bool _h264Started = false;
  // Target encode size for H.264 (the ladder picks this; default 720p).
  int _h264Width = 1280;
  int _h264Height = 720;
  int _h264Bitrate = 3000000;
  void Function(H264Au au)? onH264Au;
  bool get isH264Mode => _h264Mode;

  // ── Adaptive quality (Section 6) ─────────────────────────────────────────────
  // Start at a low-latency profile; reportBacklog() nudges it up/down. Bounds per
  // spec but defaults tuned for "live, no lag" over WiFi.
  static const int _maxFps = 30, _minFps = 15;
  static const int _maxQuality = 80, _minQuality = 40;
  static const int _maxOutWidth = 854; // ~480p-wide JPEG → small, fast to encode + send
  int _targetFps = 24;
  int _jpegQuality = 60;
  int _lowBacklogStreak = 0;

  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  bool _torchOn = false;
  // Capture at a MODEST sensor resolution so the YUV buffer we iterate is small.
  // A huge sensor frame is the main cause of per-frame CPU lag; medium keeps the
  // source ~720x480-class and the in-read downscale does the rest.
  ResolutionPreset _preset = ResolutionPreset.medium;

  void Function(Uint8List jpeg)? onJpegFrame;
  /// Optional: lets the screen apply network backpressure. Return false to make
  /// the camera skip sending this frame (e.g. socket backlog).
  bool Function()? canSendFrame;
  /// Optional: notified when the encoder restarts after a crash (Section 11).
  void Function(String reason)? onEncoderRestart;

  int get targetFps => _targetFps;
  int get jpegQuality => _jpegQuality;

  // ── Metrics (Phase 0 HUD) ────────────────────────────────────────────────────
  // Rolling average encode time (ms) and measured capture/encode FPS. Fields
  // only — no behavior change. Surfaced to the metrics overlay.
  double _avgEncodeMs = 0;
  int _encodedThisWindow = 0;
  int _encodeWindowStartMs = 0;
  int _measuredFps = 0;
  double get avgEncodeMs => _avgEncodeMs;
  int get measuredFps => _measuredFps;

  /// Human-readable current quality, e.g. "720p H.264" or "854w JPEG q60".
  String get qualityLabel => _h264Mode
      ? '${_h264Height}p H.264'
      : '${_maxOutWidth}w JPEG q$_jpegQuality';

  // ── Getters ────────────────────────────────────────────────────────────────
  CameraController? get controller => _controller;
  bool get isInitialized => _controller?.value.isInitialized ?? false;
  bool get isStreaming => _streaming;
  double get zoom => _zoom;
  double get minZoom => _minZoom;
  double get maxZoom => _maxZoom;
  bool get torchOn => _torchOn;
  bool get hasTorch => _currentLensIsBack;
  CameraLensDirection get lensDirection =>
      _cameras.isNotEmpty ? _cameras[_cameraIndex].lensDirection : CameraLensDirection.back;
  bool get _currentLensIsBack => lensDirection == CameraLensDirection.back;

  Future<bool> initialize() async {
    try {
      // Spin up the encoder isolate up front so the first frame isn't delayed.
      if (!_encoderReady) {
        await _encoder.start();
        _encoderReady = true;
      }
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return false;
      _cameraIndex = _cameras.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      if (_cameraIndex < 0) _cameraIndex = 0;
      await _startController();
      return true;
    } catch (e) {
      debugPrint('[CameraService] initialize failed: $e');
      return false;
    }
  }

  Future<void> _startController() async {
    await _disposeController();
    final controller = CameraController(
      _cameras[_cameraIndex],
      // Sensor headroom; frames are downscaled to _maxOutWidth before sending.
      _preset,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    _controller = controller;
    await controller.initialize();

    // Lock exposure/focus modes to "continuous" for a stable, sharp picture.
    try { await controller.setFocusMode(FocusMode.auto); } catch (_) {}
    try { await controller.setExposureMode(ExposureMode.auto); } catch (_) {}

    _minZoom = await controller.getMinZoomLevel();
    _maxZoom = await controller.getMaxZoomLevel();
    _zoom = _zoom.clamp(_minZoom, _maxZoom);
    try { await controller.setZoomLevel(_zoom); } catch (_) {}
    _torchOn = false;

    notifyListeners();

    if (_streaming) {
      await controller.startImageStream(_onCameraImage);
    }
  }

  Map<String, dynamic> capabilities() {
    return {
      'zoom': {'min': _minZoom, 'max': _maxZoom, 'step': 0.1, 'neutral': _minZoom},
      'torchSupported': hasTorch,
      'cameras': _cameras
          .map((c) => {
                'id': c.name,
                'label': c.lensDirection.name,
                'position': c.lensDirection == CameraLensDirection.front ? 'front' : 'back',
              })
          .toList(),
    };
  }

  /// Enable/disable H.264 hardware-encode mode. When enabling, the native
  /// encoder is started at the current target size; AUs arrive via [onH264Au].
  /// When disabling, falls back to the Dart JPEG path.
  Future<void> setH264Mode(bool enabled, {int? width, int? height, int? bitrate}) async {
    if (width != null) _h264Width = width;
    if (height != null) _h264Height = height;
    if (bitrate != null) _h264Bitrate = bitrate;
    if (enabled == _h264Mode && _h264Started) return;
    _h264Mode = enabled;
    if (enabled) {
      _h264.onAu = (au) => onH264Au?.call(au);
      _h264.onError = (r) => debugPrint('[CameraService] h264 error: $r');
      _h264Started = await _h264.start(
        width: _h264Width, height: _h264Height,
        fps: _targetFps, bitrate: _h264Bitrate,
      );
      debugPrint('[CameraService] H.264 mode ${_h264Started ? "started" : "FAILED"} '
          '${_h264Width}x$_h264Height @${_targetFps}fps ${_h264Bitrate}bps');
    } else {
      await _h264.stop();
      _h264Started = false;
    }
    notifyListeners();
  }

  /// Push the latest ABR target into the running H.264 encoder (bitrate is
  /// applied live; resolution change requires a restart — handled by the ABR
  /// controller via setH264Mode).
  Future<void> updateH264Bitrate(int bitrate) async {
    _h264Bitrate = bitrate;
    if (_h264Mode && _h264Started) await _h264.setBitrate(bitrate);
  }

  Future<void> requestH264Keyframe() async {
    if (_h264Mode && _h264Started) await _h264.requestKeyframe();
  }

  Future<void> startStreaming() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (_streaming) return;
    _streaming = true;
    try {
      await c.startImageStream(_onCameraImage);
    } catch (e) {
      debugPrint('[CameraService] startImageStream failed: $e');
      _streaming = false;
    }
    notifyListeners();
  }

  Future<void> stopStreaming() async {
    final c = _controller;
    _streaming = false;
    try {
      if (c != null && c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
    notifyListeners();
  }

  // Monotonic-ish capture clock base (µs) for AU/JPEG timestamps.
  final int _epochUs = DateTime.now().microsecondsSinceEpoch;

  void _onCameraImage(CameraImage image) {
    // FPS throttle (shared by both codecs).
    final now = DateTime.now();
    final minGapMs = (1000 / _targetFps).round();
    if (now.difference(_lastSent).inMilliseconds < minGapMs) return;

    // ── H.264 path ──────────────────────────────────────────────────────────
    // Send YUV planes straight to the native hardware encoder. No Dart encode,
    // no isolate. Network backpressure still applies (skip if the socket can't
    // take more). The native side handles its own input-buffer backpressure.
    if (_h264Mode && _h264Started) {
      if (canSendFrame != null && !canSendFrame!()) return;
      if (image.format.group != ImageFormatGroup.yuv420 || image.planes.length < 3) return;
      _lastSent = now;
      final ptsUs = DateTime.now().microsecondsSinceEpoch - _epochUs;
      _h264.encodeFrame(
        y: image.planes[0].bytes,
        u: image.planes[1].bytes,
        v: image.planes[2].bytes,
        yStride: image.planes[0].bytesPerRow,
        uvStride: image.planes[1].bytesPerRow,
        uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
        ptsUs: ptsUs,
      );
      _encodedThisWindow++;
      final nowMs = now.millisecondsSinceEpoch;
      if (_encodeWindowStartMs == 0) _encodeWindowStartMs = nowMs;
      if (nowMs - _encodeWindowStartMs >= 1000) {
        _measuredFps = (_encodedThisWindow * 1000 / (nowMs - _encodeWindowStartMs)).round();
        _encodedThisWindow = 0;
        _encodeWindowStartMs = nowMs;
      }
      return;
    }

    // ── Legacy JPEG path ────────────────────────────────────────────────────
    if (!_encoderReady || onJpegFrame == null) return;

    // Backpressure: never queue. If a frame is still encoding, or the network
    // can't take more, drop this one — realtime beats backlog.
    if (_frameInFlight) return;
    if (canSendFrame != null && !canSendFrame!()) return;

    _frameInFlight = true;
    _lastSent = now;

    final raw = _packFrame(image);
    if (raw == null) { _frameInFlight = false; return; }

    final encodeStart = DateTime.now();
    _encoder.encode(raw).then((jpeg) {
      // Rolling encode-time average + measured FPS (metrics only).
      final ms = DateTime.now().difference(encodeStart).inMilliseconds.toDouble();
      _avgEncodeMs = _avgEncodeMs == 0 ? ms : (_avgEncodeMs * 0.8 + ms * 0.2);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_encodeWindowStartMs == 0) _encodeWindowStartMs = nowMs;
      _encodedThisWindow++;
      if (nowMs - _encodeWindowStartMs >= 1000) {
        _measuredFps = (_encodedThisWindow * 1000 / (nowMs - _encodeWindowStartMs)).round();
        _encodedThisWindow = 0;
        _encodeWindowStartMs = nowMs;
      }
      if (jpeg != null && _streaming) {
        try { onJpegFrame?.call(jpeg); } catch (_) {}
      } else if (jpeg == null) {
        // A null result can mean the isolate died — restart it so streaming
        // resumes without operator action (Section 11).
        _restartEncoder('encode returned null');
      }
    }).catchError((e) {
      _restartEncoder('encode threw: $e');
    }).whenComplete(() => _frameInFlight = false);
  }

  bool _restarting = false;
  Future<void> _restartEncoder(String reason) async {
    if (_restarting) return;
    _restarting = true;
    debugPrint('[CameraService] restarting JPEG encoder: $reason');
    try { _encoder.dispose(); } catch (_) {}
    _encoder = JpegEncoder();
    try {
      await _encoder.start();
      _encoderReady = true;
      onEncoderRestart?.call(reason);
    } catch (e) {
      debugPrint('[CameraService] encoder restart failed: $e');
    } finally {
      _restarting = false;
    }
  }

  /// Adaptive quality (Section 6). The screen calls this every ~500ms with the
  /// socket's pending-byte backlog. Above 200KB → step down; sustained low
  /// backlog → step back up. Bounds: q40-85, 15-30fps.
  void reportBacklog(int pendingBytes) {
    if (pendingBytes > 200 * 1024) {
      _lowBacklogStreak = 0;
      final newQ = (_jpegQuality - 5).clamp(_minQuality, _maxQuality);
      final newF = (_targetFps - 5).clamp(_minFps, _maxFps);
      if (newQ != _jpegQuality || newF != _targetFps) {
        _jpegQuality = newQ; _targetFps = newF;
        debugPrint('[Adaptive] backlog ${(pendingBytes/1024).round()}KB → q$_jpegQuality ${_targetFps}fps (down)');
        notifyListeners();
      }
    } else if (pendingBytes < 50 * 1024) {
      _lowBacklogStreak++;
      if (_lowBacklogStreak >= 3) {
        _lowBacklogStreak = 0;
        final newQ = (_jpegQuality + 5).clamp(_minQuality, _maxQuality);
        final newF = (_targetFps + 5).clamp(_minFps, _maxFps);
        if (newQ != _jpegQuality || newF != _targetFps) {
          _jpegQuality = newQ; _targetFps = newF;
          debugPrint('[Adaptive] link clear → q$_jpegQuality ${_targetFps}fps (up)');
          notifyListeners();
        }
      }
    } else {
      _lowBacklogStreak = 0;
    }
  }

  /// Copy the camera planes into a transferable [RawFrame] for the isolate.
  RawFrame? _packFrame(CameraImage image) {
    final mirror = lensDirection == CameraLensDirection.front;
    if (image.format.group == ImageFormatGroup.yuv420) {
      if (image.planes.length < 3) return null;
      return RawFrame(
        format: 0,
        width: image.width,
        height: image.height,
        maxWidth: _maxOutWidth,
        quality: _jpegQuality,
        mirror: mirror,
        y: image.planes[0].bytes,
        u: image.planes[1].bytes,
        v: image.planes[2].bytes,
        yRowStride: image.planes[0].bytesPerRow,
        uvRowStride: image.planes[1].bytesPerRow,
        uvPixelStride: image.planes[1].bytesPerPixel ?? 1,
      );
    } else if (image.format.group == ImageFormatGroup.bgra8888) {
      return RawFrame(
        format: 1,
        width: image.width,
        height: image.height,
        maxWidth: _maxOutWidth,
        quality: _jpegQuality,
        mirror: mirror,
        bgra: image.planes[0].bytes,
      );
    }
    return null;
  }

  // ── Controls ────────────────────────────────────────────────────────────────
  Future<void> setZoom(double zoom) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final clamped = zoom.clamp(_minZoom, _maxZoom).toDouble();
    _zoom = clamped;
    try { await c.setZoomLevel(clamped); } catch (_) {}
    notifyListeners();
  }

  Future<void> switchCamera() async {
    if (_cameras.length < 2) return;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    _zoom = 1.0;
    _torchOn = false;
    await _startController();
  }

  Future<void> toggleTorch() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || !hasTorch) return;
    _torchOn = !_torchOn;
    try {
      await c.setFlashMode(_torchOn ? FlashMode.torch : FlashMode.off);
    } catch (_) {
      _torchOn = false;
    }
    notifyListeners();
  }

  /// Focus at a normalized point (0..1, 0..1). Returns true if applied.
  Future<bool> focusAt(double nx, double ny) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return false;
    final p = Offset(nx.clamp(0.0, 1.0), ny.clamp(0.0, 1.0));
    try {
      await c.setFocusPoint(p);
      await c.setExposurePoint(p);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Exposure offset, spec range -10..10 mapped into the device's supported range.
  Future<double> setExposure(double value) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return 0;
    try {
      final minE = await c.getMinExposureOffset();
      final maxE = await c.getMaxExposureOffset();
      // Map -10..10 onto the device's actual EV range.
      final t = ((value.clamp(-10.0, 10.0)) + 10) / 20.0;
      final ev = minE + (maxE - minE) * t;
      final applied = await c.setExposureOffset(ev);
      return applied;
    } catch (_) {
      return 0;
    }
  }

  /// The camera plugin has no white-balance API → always unsupported.
  bool get whiteBalanceSupported => false;

  /// Switch to a specific lens position (front/back). Returns true if changed.
  Future<bool> switchToPosition(CameraLensDirection dir) async {
    final idx = _cameras.indexWhere((c) => c.lensDirection == dir);
    if (idx < 0 || idx == _cameraIndex) return idx == _cameraIndex;
    _cameraIndex = idx;
    _zoom = 1.0;
    _torchOn = false;
    await _startController();
    return true;
  }

  /// Map a requested resolution to the nearest [ResolutionPreset] and apply it.
  /// The camera plugin can't set arbitrary width/height/fps, so we pick the
  /// closest preset and report back what was actually selected.
  Future<Map<String, int>> setResolution(int width, int height) async {
    final target = width > height ? width : height;
    ResolutionPreset preset;
    if (target >= 3840) {
      preset = ResolutionPreset.max;
    } else if (target >= 1920) {
      preset = ResolutionPreset.veryHigh;
    } else if (target >= 1280) {
      preset = ResolutionPreset.high;
    } else if (target >= 720) {
      preset = ResolutionPreset.medium;
    } else {
      preset = ResolutionPreset.low;
    }
    _preset = preset;
    await _startController();
    final c = _controller;
    final size = c?.value.previewSize;
    return {
      'width': size?.width.round() ?? width,
      'height': size?.height.round() ?? height,
    };
  }

  Future<void> _disposeController() async {
    final c = _controller;
    _controller = null;
    if (c != null) {
      try {
        if (c.value.isStreamingImages) await c.stopImageStream();
      } catch (_) {}
      try { await c.dispose(); } catch (_) {}
    }
  }

  @override
  void dispose() {
    _disposeController();
    _encoder.dispose();
    _h264.stop();
    super.dispose();
  }
}
