import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

/// Owns the camera hardware: preview, live frame capture, zoom, flip and torch.
///
/// Frames captured via [CameraController.startImageStream] are converted to JPEG
/// (downscaled + throttled for LAN throughput) and handed to [onJpegFrame], which
/// the screen wires to [ConnectionService.sendFrame].
class CameraService extends ChangeNotifier {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;

  bool _streaming = false;
  bool _converting = false; // guards against piling up conversions
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);

  // Tuning — keep CPU + bandwidth reasonable on a phone over WiFi.
  static const int _targetFps = 15;
  static const int _maxWidth = 960; // longest edge after downscale
  static const int _jpegQuality = 70;

  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  bool _torchOn = false;

  void Function(Uint8List jpeg)? onJpegFrame;

  // ── Getters ────────────────────────────────────────────────────────────────
  CameraController? get controller => _controller;
  bool get isInitialized => _controller?.value.isInitialized ?? false;
  bool get isStreaming => _streaming;
  double get zoom => _zoom;
  double get minZoom => _minZoom;
  double get maxZoom => _maxZoom;
  bool get torchOn => _torchOn;
  bool get hasTorch => _currentLensIsBack; // front cameras rarely have a torch
  CameraLensDirection get lensDirection =>
      _cameras.isNotEmpty ? _cameras[_cameraIndex].lensDirection : CameraLensDirection.back;
  bool get _currentLensIsBack => lensDirection == CameraLensDirection.back;

  /// Discover cameras and start the back camera. Returns false if none/failure.
  Future<bool> initialize() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) return false;
      // Prefer the back camera.
      _cameraIndex = _cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
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
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    _controller = controller;
    await controller.initialize();

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

  /// Build the capabilities payload for the desktop handshake (zoom slider range).
  Map<String, dynamic> capabilities() {
    return {
      'zoom': {
        'min': _minZoom,
        'max': _maxZoom,
        'step': 0.1,
        'neutral': _minZoom,
      },
      'torchSupported': hasTorch,
      'cameras': _cameras
          .map((c) => {
                'id': c.name,
                'label': c.lensDirection.name,
                'position':
                    c.lensDirection == CameraLensDirection.front ? 'front' : 'back',
              })
          .toList(),
    };
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
      if (c != null && c.value.isStreamingImages) {
        await c.stopImageStream();
      }
    } catch (_) {}
    notifyListeners();
  }

  void _onCameraImage(CameraImage image) {
    // Throttle to target FPS.
    final now = DateTime.now();
    final minGapMs = (1000 / _targetFps).round();
    if (now.difference(_lastFrame).inMilliseconds < minGapMs) return;
    if (_converting) return; // skip while a previous frame is still encoding
    _lastFrame = now;
    _converting = true;

    // Convert + encode off the platform message path. Pure Dart, but guarded so
    // only one runs at a time and dropped frames simply skip.
    Future<void>(() {
      try {
        final jpeg = _encodeToJpeg(image);
        if (jpeg != null) onJpegFrame?.call(jpeg);
      } catch (e) {
        debugPrint('[CameraService] encode error: $e');
      } finally {
        _converting = false;
      }
    });
  }

  Uint8List? _encodeToJpeg(CameraImage image) {
    img.Image? rgb;
    if (image.format.group == ImageFormatGroup.yuv420) {
      rgb = _yuv420ToImage(image);
    } else if (image.format.group == ImageFormatGroup.bgra8888) {
      rgb = _bgraToImage(image);
    }
    if (rgb == null) return null;

    // Downscale so the longest edge <= _maxWidth (keeps CPU + bandwidth in check).
    final longest = rgb.width > rgb.height ? rgb.width : rgb.height;
    if (longest > _maxWidth) {
      final scale = _maxWidth / longest;
      rgb = img.copyResize(
        rgb,
        width: (rgb.width * scale).round(),
        height: (rgb.height * scale).round(),
        interpolation: img.Interpolation.average,
      );
    }

    // Mirror the front camera so the operator sees a natural (non-mirrored) feed,
    // matching how the desktop expects it.
    if (lensDirection == CameraLensDirection.front) {
      rgb = img.flipHorizontal(rgb);
    }

    return Uint8List.fromList(img.encodeJpg(rgb, quality: _jpegQuality));
  }

  img.Image _yuv420ToImage(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final out = img.Image(width: width, height: height);

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final yRowStride = yPlane.bytesPerRow;
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;

    final yBytes = yPlane.bytes;
    final uBytes = uPlane.bytes;
    final vBytes = vPlane.bytes;

    for (int y = 0; y < height; y++) {
      final yRow = y * yRowStride;
      final uvRow = (y >> 1) * uvRowStride;
      for (int x = 0; x < width; x++) {
        final yIndex = yRow + x;
        final uvIndex = uvRow + (x >> 1) * uvPixelStride;
        if (yIndex >= yBytes.length ||
            uvIndex >= uBytes.length ||
            uvIndex >= vBytes.length) {
          continue;
        }
        final yp = yBytes[yIndex];
        final up = uBytes[uvIndex];
        final vp = vBytes[uvIndex];

        // YUV → RGB (BT.601)
        int r = (yp + 1.402 * (vp - 128)).round();
        int g = (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128)).round();
        int b = (yp + 1.772 * (up - 128)).round();

        r = r < 0 ? 0 : (r > 255 ? 255 : r);
        g = g < 0 ? 0 : (g > 255 ? 255 : g);
        b = b < 0 ? 0 : (b > 255 ? 255 : b);

        out.setPixelRgb(x, y, r, g, b);
      }
    }
    return out;
  }

  img.Image _bgraToImage(CameraImage image) {
    return img.Image.fromBytes(
      width: image.width,
      height: image.height,
      bytes: image.planes[0].bytes.buffer,
      order: img.ChannelOrder.bgra,
    );
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
    super.dispose();
  }
}
