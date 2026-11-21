import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/connection_service.dart';
import '../services/camera_service.dart';
import '../services/abr_controller.dart';
import '../services/device_status_service.dart';
import '../services/orientation_service.dart';
import '../services/storage.dart';
import '../services/smart_framer.dart';
import '../models/camera_filters.dart';
import '../utils/permissions.dart';
import '../widgets/reading_overlay.dart';
import '../widgets/connection_badge.dart';
import '../widgets/metrics_overlay.dart';
import '../widgets/filtered_preview.dart';

const _purple = Color(0xFF818CF8);

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  final CameraService _camera = CameraService();
  final OrientationService _orientation = OrientationService();
  final DeviceStatusService _deviceStatus = DeviceStatusService();
  Timer? _statusTimer;

  bool _permissionDenied = false;
  bool _initializing = true;
  String? _initError;

  CameraFilters _filters = CameraFilters.none;
  bool _showFilters = false;

  // Pinch-to-zoom
  double _baseZoom = 1.0;
  bool _showZoomBar = false;
  Timer? _zoomBarTimer;

  // Smart Zoom: while this mode is on, tapping a person locks the shot on them.
  bool _smartMode = false;
  // Live switcher (pick which desktop camera is on air).
  bool _showSwitcher = false;

  // Phone → desktop state report (zoom + Smart Zoom), throttled.
  Timer? _stateReportTimer;
  bool _stateReportQueued = false;

  // Focus ring
  Offset? _focusPoint;
  Timer? _focusTimer;

  Timer? _adaptiveTimer;
  ConnectionService? _conn;
  AbrController? _abr;
  bool _showMetrics = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _conn = context.read<ConnectionService>();
    _conn!.addCommandListener(_onRemoteCommand);
    _conn!.stateProvider = _buildStateRestore;
    _orientation.addListener(_onOrientation);
    _orientation.start();
    _deviceStatus.start();
    // Push battery + wifi to the desktop every 5s (and refresh the HUD).
    _deviceStatus.addListener(() { if (mounted) setState(() {}); });
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _conn?.sendDeviceStatus(_deviceStatus.toJson());
    });
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final granted = await requestCameraPermission();
    if (!mounted) return;
    if (!granted) {
      setState(() { _permissionDenied = true; _initializing = false; });
      return;
    }
    final ok = await _camera.initialize();
    if (!mounted) return;
    if (!ok) {
      setState(() { _initError = 'No camera available on this device.'; _initializing = false; });
      return;
    }

    // Restore last filters for this camera.
    _filters = await loadFilters(_camera.lensDirection.name);

    _conn?.sendCapabilities(_camera.capabilities());
    _camera.onSmartZoomChanged = _reportPhoneState;
    _camera.onJpegFrame = (jpeg) => _conn?.sendFrame(jpeg);
    _camera.canSendFrame = () => _conn?.canAcceptFrame ?? false;
    _camera.onEncoderRestart = (reason) => _conn?.reportUnsupported('encoder', 'restarted: $reason');

    // H.264: forward each hardware access unit as a v2 wire frame, stamping the
    // current orientation + front-camera mirror so the desktop bakes them in.
    _camera.onH264Au = (au) {
      _conn?.sendV2Frame(
        type: au.type,
        payload: au.data,
        captureTsUs: au.ptsUs,
        mirror: _camera.lensDirection == CameraLensDirection.front,
        rotation: _orientation.angle,
      );
    };
    // If the desktop negotiated h264, switch the camera into hardware-encode
    // mode at the user's SELECTED resolution/fps (from Settings). Wrapped so an
    // encoder/camera failure falls back gracefully.
    if (_conn?.videoCodec == 'h264') {
      try {
        final s = await loadSettings();
        final longEdge = s.videoLongEdge; // 3840=4K … 640=360p
        final fps = s.videoFps;           // 30 | 60
        final bitrate = CameraService.bitrateFor(longEdge, fps);
        await _camera.setH264Mode(true,
            width: longEdge, height: (longEdge * 9 / 16).round(),
            fps: fps, bitrate: bitrate);
        // ABR may step DOWN under congestion but never above the user's choice.
        _abr = AbrController(
          startTier: AbrController.tierForLongEdge(longEdge, fps),
          onTierChange: (t) async {
            await _camera.setH264Mode(true, width: t.width, height: t.height, fps: t.fps, bitrate: t.bitrate);
            await _camera.requestH264Keyframe();
          },
          onBitrate: (br) => _camera.updateH264Bitrate(br),
        );
        debugPrint('[CameraScreen] H.264 start @ ${longEdge}p ${fps}fps ${bitrate ~/ 1000}kbps');
      } catch (e) {
        debugPrint('[CameraScreen] H.264 setup failed, staying on MJPEG: $e');
      }
    }
    // On every (re)connect of the video socket, force a fresh config+keyframe so
    // the desktop decoder can initialize without a stall.
    _conn?.onVideoReady = () => _camera.requestH264Keyframe();

    await _camera.startStreaming();
    _camera.addListener(_onCameraChanged);

    // Adaptive-quality tick — 400ms for a fast reaction to link changes so the
    // quality recovers quickly and latency never accumulates (MJPEG backlog path).
    _adaptiveTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final abr = _abr;
      if (abr != null && _camera.isH264Mode) {
        abr.tick(pendingBytes: _conn?.pendingVideoBytes ?? 0, targetFps: _camera.targetFps);
      } else {
        _camera.reportBacklog(_conn?.pendingVideoBytes ?? 0);
      }
    });

    if (mounted) setState(() => _initializing = false);
    _reportPhoneState();
  }

  /// Tell the desktop the phone's current zoom + Smart Zoom state so its
  /// controls show the truth. Throttled to ≤ ~7/s with a trailing send.
  void _reportPhoneState() {
    if (_stateReportTimer?.isActive ?? false) { _stateReportQueued = true; return; }
    _sendPhoneStateNow();
    _stateReportTimer = Timer(const Duration(milliseconds: 150), () {
      if (_stateReportQueued) { _stateReportQueued = false; _sendPhoneStateNow(); }
    });
  }

  void _sendPhoneStateNow() {
    _conn?.sendPhoneState({
      'zoom': _camera.zoom,
      'zoomMin': _camera.minZoom,
      'zoomMax': _camera.maxZoom,
      'hardwareZoom': _camera.hasHardwareZoom,
      'smartZoom': _camera.smartZoomState(),
    });
  }

  // ALWAYS LANDSCAPE: the app is locked to landscape, so the feed is always
  // horizontal. We report angle 0 to the desktop at all times → the studio
  // output stays horizontal, matching the phone's locked orientation.
  static const int _kForcedAngle = 0;

  Map<String, dynamic> _buildStateRestore() => {
        'capabilities': _camera.capabilities(),
        'orientationAngle': _kForcedAngle,
        'zoom': _camera.zoom,
        'filters': _filters.toJson(),
      };

  void _onCameraChanged() { if (mounted) setState(() {}); }

  void _onOrientation() {
    _conn?.sendOrientationAngle(_kForcedAngle);
    if (mounted) setState(() {});
  }

  // ── Desktop → mobile controls (Section 4) ────────────────────────────────────
  Future<void> _onRemoteCommand(RemoteCommand cmd) async {
    final conn = _conn;
    switch (cmd.action) {
      case 'rx_stats':
        // Desktop receive/decoder health → feed the ABR controller.
        final v = cmd.value;
        if (v is Map && _abr != null) {
          _abr!.updateRxStats(RxStats(
            decodeFps: (v['decodeFps'] as num?)?.toDouble() ?? 0,
            queueDepth: (v['queueDepth'] as num?)?.toInt() ?? 0,
            frameAgeMs: (v['frameAgeMs'] as num?)?.toDouble() ?? 0,
          ));
        }
        break;
      case 'set_zoom':
      case 'zoom':
        if (cmd.value is num) {
          final z = (cmd.value as num).toDouble();
          // Big jumps (preset buttons) glide like a zoom rocker; small steps
          // (a slider being dragged) apply directly so they track the hand.
          if ((z - _camera.zoom).abs() > 0.6) {
            _camera.animateZoomTo(z);
          } else {
            await _camera.setZoom(z);
          }
          conn?.confirmControl('zoom', z);
          _showZoomIndicator();
          _reportPhoneState();
        }
        break;
      case 'smart_zoom':
        // Desktop-driven Smart Zoom. Coordinates from the desktop are relative
        // to the PROGRAM picture it shows (already cropped), so they're mapped
        // back through the current crop on this side.
        if (cmd.value is Map) {
          final v = cmd.value as Map;
          final act = (v['action'] ?? '').toString();
          final zoom = (v['zoom'] as num?)?.toDouble();
          if (act == 'lock') {
            final x = (v['x'] as num?)?.toDouble() ?? 0.5;
            final y = (v['y'] as num?)?.toDouble() ?? 0.5;
            if (v['space'] == 'full') {
              _camera.smartLock(Offset(x, y), zoom: zoom);
            } else {
              _camera.smartLockProgram(Offset(x, y), zoom: zoom);
            }
            if (mounted) setState(() => _smartMode = true);
          } else if (act == 'release') {
            _camera.smartRelease();
          } else if (act == 'shot' && zoom != null) {
            _camera.smartSetShot(zoom);
          } else if (act == 'follow') {
            _camera.smartSetFollow(v['value'] == true);
          }
          conn?.confirmControl('smart_zoom', _camera.smartZoomState());
          _reportPhoneState();
        }
        break;
      case 'focus':
        if (cmd.value is Map) {
          final x = (cmd.value['x'] as num?)?.toDouble() ?? 0.5;
          final y = (cmd.value['y'] as num?)?.toDouble() ?? 0.5;
          final ok = await _camera.focusAt(x, y);
          _ringAt(Offset(x, y));
          conn?.confirmControl('focus', ok);
        }
        break;
      case 'exposure':
      case 'set_exposure':
        if (cmd.value is num) {
          final applied = await _camera.setExposure((cmd.value as num).toDouble());
          conn?.confirmControl('exposure', applied);
        }
        break;
      case 'focus_lock':
        {
          final lock = cmd.value == true || cmd.value == 'on' || cmd.value == 'lock';
          final ok = await _camera.setFocusLocked(lock);
          conn?.confirmControl('focus_lock', ok ? (lock ? 'locked' : 'auto') : 'unsupported');
        }
        break;
      case 'exposure_lock':
        {
          final lock = cmd.value == true || cmd.value == 'on' || cmd.value == 'lock';
          final ok = await _camera.setExposureLocked(lock);
          conn?.confirmControl('exposure_lock', ok ? (lock ? 'locked' : 'auto') : 'unsupported');
        }
        break;
      case 'white_balance':
      case 'set_white_balance':
        if (_camera.whiteBalanceSupported) {
          conn?.confirmControl('white_balance', cmd.value);
        } else {
          conn?.reportUnsupported('white_balance', 'not supported on this device');
        }
        break;
      case 'torch':
      case 'toggle_torch':
      case 'set_torch':
        {
          // set_torch carries an explicit on/off; torch/toggle_torch toggle.
          final v = cmd.value;
          final wantOn = v == true || v == 'on' || v == 1;
          final wantOff = v == false || v == 'off' || v == 0;
          if (wantOn && !_camera.torchOn) await _camera.toggleTorch();
          else if (wantOff && _camera.torchOn) await _camera.toggleTorch();
          else if (!wantOn && !wantOff) await _camera.toggleTorch(); // no explicit value → toggle
          conn?.confirmControl('torch', _camera.torchOn ? 'on' : 'off');
        }
        break;
      case 'flip':
      case 'switch_camera':
      case 'camera_flip':
        if (cmd.value == 'front') {
          await _camera.switchToPosition(CameraLensDirection.front);
        } else if (cmd.value == 'back') {
          await _camera.switchToPosition(CameraLensDirection.back);
        } else {
          await _camera.switchCamera();
        }
        conn?.sendCapabilities(_camera.capabilities());
        conn?.confirmControl('flip', _camera.lensDirection.name);
        break;
      case 'set_format':
      case 'format':
        // Desktop requests an encoder format/resolution. Map to setResolution.
        if (cmd.value is Map) {
          final w = (cmd.value['width'] as num?)?.toInt() ?? 1280;
          final h = (cmd.value['height'] as num?)?.toInt() ?? 720;
          final applied = await _camera.setResolution(w, h);
          conn?.confirmControl('format', applied);
        } else {
          conn?.reportUnsupported('set_format', 'expected {width,height}');
        }
        break;
      case 'resolution':
        if (cmd.value is Map) {
          final w = (cmd.value['width'] as num?)?.toInt() ?? 1280;
          final h = (cmd.value['height'] as num?)?.toInt() ?? 720;
          final applied = await _camera.setResolution(w, h);
          conn?.confirmControl('resolution', applied);
        }
        break;
      case 'filters':
      case 'filter_state':
        if (cmd.value is Map) {
          setState(() => _filters = CameraFilters.fromJson(cmd.value as Map));
          await saveFilters(_camera.lensDirection.name, _filters);
          conn?.confirmControl('filters', _filters.toJson());
        }
        break;
      case 'desktop_state':
        // Informational (camera list, tally, transition) — ConnectionService
        // already stored it and the UI listens there. Not a command.
        break;
      default:
        // Log + report anything we don't handle so the desktop knows.
        debugPrint('[CameraScreen] unsupported command: ${cmd.action}');
        conn?.reportUnsupported(cmd.action, 'not implemented on mobile');
        break;
    }
  }

  // ── Local filter change → push to desktop + persist ──────────────────────────
  Future<void> _setFilters(CameraFilters f) async {
    setState(() => _filters = f);
    await saveFilters(_camera.lensDirection.name, f);
    _conn?.sendControl('filters', f.toJson());
  }

  // Local zoom is applied ON THE PHONE (hardware, or digital crop when the lens
  // has no zoom) — so it's already in the picture the desktop receives. It used
  // to also send 'set_zoom' to the desktop, which the desktop applied to its
  // USB webcam instead of this phone. Now we only REPORT the value.
  Future<void> _applyZoom(double z) async {
    await _camera.setZoom(z);
    _showZoomIndicator();
    _reportPhoneState();
  }

  void _animateZoom(double z) {
    _camera.animateZoomTo(z);
    _showZoomIndicator();
    Future.delayed(const Duration(milliseconds: 700), _reportPhoneState);
  }

  void _showZoomIndicator() {
    if (!mounted) return;
    setState(() => _showZoomBar = true);
    _zoomBarTimer?.cancel();
    _zoomBarTimer = Timer(const Duration(seconds: 2), () { if (mounted) setState(() => _showZoomBar = false); });
  }

  // ── Smart Zoom (phone side) ──────────────────────────────────────────────────
  /// Where the camera frame actually sits on screen (preview is cover-fitted,
  /// so part of it is cropped off the screen edges).
  Rect _frameRectOnScreen(Size size) {
    final controller = _camera.controller;
    if (controller == null) return Offset.zero & size;
    final ar = controller.value.aspectRatio;
    final landscapeAr = ar > 1 ? ar : (1 / ar);
    final fw = landscapeAr * 1000, fh = 1000.0;
    final s = math.max(size.width / fw, size.height / fh);
    final dw = fw * s, dh = fh * s;
    return Rect.fromLTWH((size.width - dw) / 2, (size.height - dh) / 2, dw, dh);
  }

  Offset _screenToFrame(Offset p, Size size) {
    final r = _frameRectOnScreen(size);
    return Offset(((p.dx - r.left) / r.width).clamp(0.0, 1.0), ((p.dy - r.top) / r.height).clamp(0.0, 1.0));
  }

  void _toggleSmartMode() {
    setState(() => _smartMode = !_smartMode);
    if (!_smartMode && _camera.smartZoomActive) _camera.smartRelease();
  }

  void _smartTap(TapDownDetails d, Size size) {
    final p = _screenToFrame(d.localPosition, size);
    _camera.smartLock(p);
    // Focus + expose on the person too — they're the subject now.
    _camera.focusAt(p.dx, p.dy);
    _ringAt(Offset(d.localPosition.dx / size.width, d.localPosition.dy / size.height));
  }

  void _ringAt(Offset normalized) {
    setState(() => _focusPoint = normalized);
    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(milliseconds: 900), () { if (mounted) setState(() => _focusPoint = null); });
  }

  Future<void> _tapFocus(TapDownDetails d, Size size) async {
    final nx = (d.localPosition.dx / size.width).clamp(0.0, 1.0);
    final ny = (d.localPosition.dy / size.height).clamp(0.0, 1.0);
    await _camera.focusAt(nx, ny);
    _ringAt(Offset(nx, ny));
    _conn?.sendControl('focus', {'x': nx, 'y': ny});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _camera.stopStreaming();
    } else if (state == AppLifecycleState.resumed) {
      if (_camera.isInitialized) _camera.startStreaming();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _adaptiveTimer?.cancel();
    _statusTimer?.cancel();
    _focusTimer?.cancel();
    _zoomBarTimer?.cancel();
    _stateReportTimer?.cancel();
    _camera.onSmartZoomChanged = null;
    _deviceStatus.dispose();
    _abr?.dispose();
    _conn?.removeCommandListener(_onRemoteCommand);
    _conn?.stateProvider = null;
    _conn?.onVideoReady = null;
    _orientation.removeListener(_onOrientation);
    _orientation.dispose();
    _camera.removeListener(_onCameraChanged);
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_permissionDenied) return _permissionDeniedView();
    if (_initError != null) return _errorView(_initError!);
    if (_initializing || !_camera.isInitialized) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 16),
          Text('Starting camera…', style: TextStyle(color: Colors.white70)),
        ]),
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      return Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            // Opaque: the preview must win every touch on it, including the
            // second finger of a pinch landing on an empty area.
            behavior: HitTestBehavior.opaque,
            onScaleStart: (_) => _baseZoom = _camera.zoom,
            onScaleUpdate: (d) {
              if (d.pointerCount >= 2 && (d.scale - 1.0).abs() > 0.01) _applyZoom(_baseZoom * d.scale);
            },
            onTapDown: (d) => _smartMode ? _smartTap(d, size) : _tapFocus(d, size),
            child: FilteredPreview(filters: _filters, child: _buildPreview()),
          ),

          // Smart Zoom framing: dims what the audience does NOT see and marks
          // the followed person. Repaints from the camera's framing ticks only.
          IgnorePointer(
            child: CustomPaint(
              size: size,
              painter: _FramingPainter(
                camera: _camera,
                frameRect: _frameRectOnScreen(size),
                showFrame: _smartMode || !_camera.framer.isIdentity,
              ),
            ),
          ),

          // ON AIR tally — red rim when the desktop has THIS phone live.
          Consumer<ConnectionService>(
            builder: (_, conn, __) => conn.isSelfLive
                ? IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(color: const Color(0xFFEF4444), width: 4)),
                      alignment: Alignment.topCenter,
                      padding: const EdgeInsets.only(top: 10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(color: const Color(0xFFEF4444), borderRadius: BorderRadius.circular(6)),
                        child: const Text('ON AIR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 1.5, fontSize: 12)),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          if (_smartMode && !_camera.smartZoomActive)
            Positioned(
              top: 96, left: 0, right: 0,
              child: IgnorePointer(child: Center(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(20), border: Border.all(color: _purple)),
                child: const Text('اضغط على الشخص اللي عايز تتابعه  •  Tap a person to follow',
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              ))),
            ),

          if (_focusPoint != null)
            Positioned(
              left: _focusPoint!.dx * size.width - 30,
              top: _focusPoint!.dy * size.height - 30,
              child: _FocusRing(),
            ),

          // Connection badge (top-left) — tap to toggle the full metrics HUD.
          Positioned(
            top: 44, left: 16,
            child: GestureDetector(
              onTap: () => setState(() => _showMetrics = !_showMetrics),
              child: const ConnectionBadge(),
            ),
          ),

          // Metrics HUD (top-left, under the badge)
          if (_showMetrics)
            Positioned(top: 84, left: 16, child: MetricsOverlay(camera: _camera, status: _deviceStatus)),

          // Torch + flip quick toggles (top-right)
          Positioned(top: 40, right: 12, child: Row(children: [
            // AF-L: hold focus
            _labelToggle('AF-L', _camera.focusLocked,
                () => _camera.setFocusLocked(!_camera.focusLocked)),
            const SizedBox(width: 8),
            // AE-L: hold exposure
            _labelToggle('AE-L', _camera.exposureLocked,
                () => _camera.setExposureLocked(!_camera.exposureLocked)),
            const SizedBox(width: 8),
            _labelToggle('🎯 SMART', _smartMode, _toggleSmartMode),
            const SizedBox(width: 8),
            _circle(_camera.torchOn ? Icons.flash_on : Icons.flash_off,
                _camera.hasTorch ? () => _camera.toggleTorch() : null),
            const SizedBox(width: 8),
            _circle(Icons.cameraswitch, () async {
              await _camera.switchCamera();
              if (mounted) setState(() => _smartMode = false);
              _conn?.sendCapabilities(_camera.capabilities());
              _reportPhoneState();
            }),
          ])),

          if (_showZoomBar) _buildZoomBar(),

          // Bottom collapsible panel
          _buildBottomPanel(),

          // Reading text bar (very bottom)
          Consumer<ConnectionService>(
            builder: (_, conn, __) => ReadingOverlay(text: conn.readingText),
          ),
        ],
      );
    });
  }

  Widget _buildPreview() {
    final controller = _camera.controller!;
    // Landscape-locked: fill the whole screen with the camera feed. The camera
    // reports its aspect ratio in the sensor's natural (portrait) orientation, so
    // in landscape we use its INVERSE. BoxFit.cover crops to fill without bars.
    final ar = controller.value.aspectRatio;
    final landscapeAr = ar > 1 ? ar : (1 / ar); // ensure ≥1 (wide) for landscape
    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: landscapeAr * 1000,
            height: 1000,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }

  Widget _buildZoomBar() {
    final pct = _camera.maxZoom > _camera.minZoom
        ? (_camera.zoom - _camera.minZoom) / (_camera.maxZoom - _camera.minZoom) : 0.0;
    return Positioned(
      bottom: 200, left: 0, right: 0,
      child: Center(child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0x66818CF8))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 100, child: ClipRRect(borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(value: pct.clamp(0.0, 1.0), backgroundColor: Colors.white24, valueColor: const AlwaysStoppedAnimation(_purple), minHeight: 4))),
          const SizedBox(width: 10),
          Text('${_camera.zoom.toStringAsFixed(1)}×', style: const TextStyle(color: _purple, fontWeight: FontWeight.bold)),
          if (!_camera.hasHardwareZoom) ...[
            const SizedBox(width: 6),
            const Text('digital', style: TextStyle(color: Colors.white54, fontSize: 11)),
          ],
        ]),
      )),
    );
  }

  Widget _buildBottomPanel() {
    final zMin = _camera.minZoom;
    final zMax = _camera.maxZoom > zMin ? _camera.maxZoom : zMin + 1;
    final step = (zMax - zMin) / 10;
    // Quick-zoom presets that exist on this lens.
    final presets = <double>[1, 2, 3, 5].where((z) => z >= zMin - 0.01 && z <= zMax + 0.01).toList();
    return Positioned(
      bottom: 0, left: 0, right: 0,
      child: Container(
        color: const Color(0x99000000),
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 26),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header row: zoom −/slider/+ , presets, panels
          Row(children: [
            _miniBtn(Icons.zoom_out, () => _applyZoom(_camera.zoom - step)),
            Expanded(child: Slider(
              value: _camera.zoom.clamp(zMin, zMax),
              min: zMin, max: zMax,
              activeColor: _purple,
              onChanged: (v) => _applyZoom(v),
            )),
            _miniBtn(Icons.zoom_in, () => _applyZoom(_camera.zoom + step)),
            const SizedBox(width: 6),
            ...presets.map((z) => Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: _pill('${z.toStringAsFixed(0)}×', (_camera.zoom - z).abs() < 0.05, () => _animateZoom(z)),
                )),
            IconButton(
              tooltip: 'Live switcher',
              icon: Icon(Icons.switch_video, color: _showSwitcher ? _purple : Colors.white70),
              onPressed: () => setState(() { _showSwitcher = !_showSwitcher; if (_showSwitcher) _showFilters = false; }),
            ),
            IconButton(
              tooltip: 'Filters',
              icon: Icon(Icons.auto_awesome, color: _showFilters ? _purple : Colors.white70),
              onPressed: () => setState(() { _showFilters = !_showFilters; if (_showFilters) _showSwitcher = false; }),
            ),
          ]),

          if (_smartMode) _buildSmartRow(),
          if (_showSwitcher) _buildSwitcher(),

          if (_showFilters) ...[
            SizedBox(height: 44, child: ListView(
              scrollDirection: Axis.horizontal,
              children: kFilterPresets.map((p) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ActionChip(
                  backgroundColor: const Color(0xFF1E1E32),
                  label: Text(p.name, style: const TextStyle(color: Colors.white, fontSize: 12)),
                  onPressed: () => _setFilters(p.filters),
                ),
              )).toList(),
            )),
            _filterSlider('Brightness', _filters.brightness, 0, 200, (v) => _setFilters(_filters.copyWith(brightness: v))),
            _filterSlider('Contrast', _filters.contrast, 0, 200, (v) => _setFilters(_filters.copyWith(contrast: v))),
            _filterSlider('Saturation', _filters.saturation, 0, 200, (v) => _setFilters(_filters.copyWith(saturation: v))),
            _filterSlider('Blur', _filters.blur, 0, 10, (v) => _setFilters(_filters.copyWith(blur: v))),
          ],
        ]),
      ),
    );
  }

  /// Smart Zoom controls: shot size, follow on/off, release.
  Widget _buildSmartRow() {
    final f = _camera.framer;
    final active = _camera.smartZoomActive;
    final lost = active && _camera.tracker.lost;
    final shots = const [
      ('Wide', ShotSize.wide),
      ('Medium', ShotSize.medium),
      ('Close', ShotSize.close),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Row(children: [
        Icon(lost ? Icons.person_off : Icons.person_pin_circle,
            color: lost ? const Color(0xFFF59E0B) : (active ? const Color(0xFF22C55E) : Colors.white54), size: 20),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            !active ? 'Smart Zoom: tap a person' : (lost ? 'Lost — tap to re-lock' : (f.follow ? 'Following' : 'Locked')),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: lost ? const Color(0xFFF59E0B) : Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        ...shots.map((s) => Padding(
              padding: const EdgeInsets.only(left: 6),
              child: _pill(s.$1, (f.shotZoom - s.$2).abs() < 0.01, () { _camera.smartSetShot(s.$2); setState(() {}); }),
            )),
        const SizedBox(width: 10),
        _pill(f.follow ? 'Follow ✓' : 'Follow', f.follow, () { _camera.smartSetFollow(!f.follow); setState(() {}); }),
        const SizedBox(width: 6),
        if (active) _pill('Release ✕', false, () { _camera.smartRelease(); setState(() {}); }),
      ]),
    );
  }

  /// Live switcher: every camera the desktop can put on air (USB, IP, phones),
  /// plus the transition used for the cut.
  Widget _buildSwitcher() {
    return Consumer<ConnectionService>(builder: (_, conn, __) {
      final cams = conn.desktopCameras;
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 46,
          child: cams.isEmpty
              ? const Center(child: Text('No cameras reported by the desktop yet', style: TextStyle(color: Colors.white54, fontSize: 12)))
              : ListView(
                  scrollDirection: Axis.horizontal,
                  children: cams.map((c) {
                    final live = conn.activeCameraId == c.id;
                    final self = c.id == conn.selfCameraId;
                    final icon = c.kind == 'ip' ? Icons.router : (c.kind == 'mobile' || c.kind == 'webrtc') ? Icons.smartphone : Icons.videocam;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8, top: 4, bottom: 4),
                      child: GestureDetector(
                        onTap: () => conn.selectDesktopCamera(c.id),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: live ? const Color(0xFFDC2626) : const Color(0xCC141423),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: live ? const Color(0xFFEF4444) : (self ? _purple : Colors.white24), width: live || self ? 1.5 : 1),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(icon, color: Colors.white, size: 16),
                            const SizedBox(width: 6),
                            Text(self ? 'This phone' : c.label,
                                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: live ? FontWeight.w800 : FontWeight.w500)),
                            if (live) ...[
                              const SizedBox(width: 6),
                              const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900)),
                            ],
                          ]),
                        ),
                      ),
                    );
                  }).toList(),
                ),
        ),
        if (conn.transitions.isNotEmpty)
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: conn.transitions.map((t) => Padding(
                    padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
                    child: _pill(t.labelAr.isNotEmpty ? t.labelAr : t.label, conn.switchTransition == t.id, () => conn.setSwitchTransition(t.id)),
                  )).toList(),
            ),
          ),
      ]);
    });
  }

  Widget _miniBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34, height: 34,
          decoration: const BoxDecoration(color: Color(0xBF141423), shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 18),
        ),
      );

  Widget _pill(String label, bool active, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? _purple : const Color(0xBF141423),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: active ? _purple : Colors.white24),
          ),
          child: Text(label, style: TextStyle(color: active ? Colors.black : Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
        ),
      );

  Widget _filterSlider(String label, double value, double min, double max, ValueChanged<double> onChanged) => Row(children: [
        SizedBox(width: 80, child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11))),
        Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, activeColor: _purple, onChanged: onChanged)),
        SizedBox(width: 34, child: Text(value.round().toString(), style: const TextStyle(color: Colors.white54, fontSize: 11))),
      ]);

  Widget _circle(IconData icon, VoidCallback? onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 42, height: 42,
          decoration: const BoxDecoration(color: Color(0xBF141423), shape: BoxShape.circle),
          child: Icon(icon, color: onTap == null ? Colors.white30 : Colors.white, size: 20),
        ),
      );

  /// Pill toggle (e.g. AF-L / AE-L). Amber when active to read as "locked".
  Widget _labelToggle(String label, bool active, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: active ? const Color(0xCCF59E0B) : const Color(0xBF141423),
            borderRadius: BorderRadius.circular(21),
            border: Border.all(
                color: active ? const Color(0xFFF59E0B) : Colors.transparent, width: 1.5),
          ),
          alignment: Alignment.center,
          child: Text(label,
              style: TextStyle(
                  color: active ? Colors.black : Colors.white,
                  fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
        ),
      );

  void _disconnect() {
    context.read<ConnectionService>().disconnect();
    Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
  }

  Widget _permissionDeniedView() => Center(child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.camera_alt, color: Colors.white54, size: 64),
          const SizedBox(height: 20),
          const Text('Camera Permission Required', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          const Text('Church Cam needs camera access to stream video to the desktop.', style: TextStyle(color: Colors.white60), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ElevatedButton(onPressed: openCameraSettings, child: const Text('Open Settings')),
          TextButton(onPressed: _disconnect, child: const Text('← Back')),
        ]),
      ));

  Widget _errorView(String message) => Center(child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 64),
          const SizedBox(height: 20),
          Text(message, style: const TextStyle(color: Colors.white, fontSize: 16), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ElevatedButton(onPressed: _disconnect, child: const Text('← Back')),
        ]),
      ));
}

/// Draws the Smart Zoom program frame over the full camera preview: everything
/// outside the crop is dimmed, the crop gets broadcast-style corner marks, and
/// the followed person gets a marker (amber when the tracker has lost them).
class _FramingPainter extends CustomPainter {
  final CameraService camera;
  final Rect frameRect;
  final bool showFrame;
  _FramingPainter({required this.camera, required this.frameRect, required this.showFrame})
      : super(repaint: camera.framingTick);

  Offset _toScreen(Offset p) => Offset(frameRect.left + p.dx * frameRect.width, frameRect.top + p.dy * frameRect.height);

  @override
  void paint(Canvas canvas, Size size) {
    if (!showFrame) return;
    final f = camera.framer;
    final c = f.crop;
    final r = Rect.fromPoints(_toScreen(c.topLeft), _toScreen(c.bottomRight));

    if (!f.isIdentity) {
      final dim = Paint()..color = const Color(0x8C000000);
      final outer = Path()..addRect(Offset.zero & size);
      final hole = Path()..addRect(r);
      canvas.drawPath(Path.combine(PathOperation.difference, outer, hole), dim);
    }

    // Corner marks.
    final cornerPaint = Paint()
      ..color = f.locked ? const Color(0xFFFFFFFF) : const Color(0xAAFFFFFF)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    final len = math.min(r.width, r.height) * 0.12;
    for (final corner in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      final sx = corner.dx == r.left ? 1.0 : -1.0;
      final sy = corner.dy == r.top ? 1.0 : -1.0;
      canvas.drawLine(corner, corner + Offset(len * sx, 0), cornerPaint);
      canvas.drawLine(corner, corner + Offset(0, len * sy), cornerPaint);
    }

    final s = f.subject;
    if (f.locked && s != null) {
      final lost = camera.tracker.lost;
      final p = _toScreen(s);
      final mark = Paint()
        ..color = lost ? const Color(0xFFF59E0B) : const Color(0xFF22C55E)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(p, 18, mark);
      canvas.drawCircle(p, 3, mark..style = PaintingStyle.fill);
    }
  }

  @override
  bool shouldRepaint(covariant _FramingPainter old) =>
      old.frameRect != frameRect || old.showFrame != showFrame || old.camera != camera;
}

class _FocusRing extends StatefulWidget {
  @override
  State<_FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<_FocusRing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 350))..forward();

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => ScaleTransition(
        scale: Tween(begin: 1.4, end: 1.0).animate(CurvedAnimation(parent: _c, curve: Curves.easeOut)),
        child: Container(
          width: 60, height: 60,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: _purple, width: 2)),
        ),
      );
}
