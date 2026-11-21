import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
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
import '../widgets/metrics_overlay.dart';
import '../widgets/filtered_preview.dart';
import '../ui/tokens.dart';
import '../ui/components.dart';
import 'control_screen.dart';
import 'settings_screen.dart';

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

  // Which side-panel tab is open (null = clean viewfinder).
  _Tab? _tab;

  // Pinch-to-zoom
  double _baseZoom = 1.0;
  bool _showZoomBar = false;
  Timer? _zoomBarTimer;

  // Smart Zoom: while this mode is on, tapping a person locks the shot on them.
  bool _smartMode = false;

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
    // A reconnect creates a fresh device on the desktop with no zoom/Smart Zoom
    // state, so re-send ours along with the keyframe request.
    _conn?.onVideoReady = () {
      _camera.requestH264Keyframe();
      _reportPhoneState();
    };

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

  // ══════════════════════════════════════════════════════════════════════════
  //  UI
  //  Landscape broadcast-camera layout:
  //    • full-bleed viewfinder (pinch anywhere to zoom, tap to focus / pick)
  //    • left icon rail = tabs (Live · Smart · Image · Studio · Settings);
  //      a tab slides a panel in beside it, the picture stays live
  //    • top HUD: link, Wi-Fi, battery · tally · format
  //    • right tool rail: lens, torch, AF lock, AE lock, Smart
  //    • bottom zoom dial: presets + drag-to-scrub
  // ══════════════════════════════════════════════════════════════════════════
  static const double _railW = 72;

  double _panelW(Size size) => math.min(380.0, math.max(300.0, size.width * 0.38));

  void _openTab(_Tab t) {
    setState(() => _tab = _tab == t ? null : t);
  }

  @override
  Widget build(BuildContext context) {
    if (_permissionDenied) return _permissionDeniedView();
    if (_initError != null) return _errorView(_initError!);
    if (_initializing || !_camera.isInitialized) return _startingView();

    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      final panelW = _panelW(size);
      final panelOpen = _tab != null;
      final contentLeft = _railW + (panelOpen ? panelW : 0);

      return Stack(
        fit: StackFit.expand,
        children: [
          // ── Viewfinder ─────────────────────────────────────────────────────
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: (_) => _baseZoom = _camera.zoom,
            onScaleUpdate: (d) {
              if (d.pointerCount >= 2 && (d.scale - 1.0).abs() > 0.01) _applyZoom(_baseZoom * d.scale);
            },
            onTapDown: (d) {
              if (panelOpen) { setState(() => _tab = null); return; }
              _smartMode ? _smartTap(d, size) : _tapFocus(d, size);
            },
            child: FilteredPreview(filters: _filters, child: _buildPreview()),
          ),

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

          if (_focusPoint != null)
            Positioned(
              left: _focusPoint!.dx * size.width - 36,
              top: _focusPoint!.dy * size.height - 36,
              child: const IgnorePointer(child: _FocusRing()),
            ),

          // ON AIR rim
          Consumer<ConnectionService>(
            builder: (_, conn, __) => IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  border: Border.all(color: conn.isSelfLive ? C.tally : Colors.transparent, width: 3),
                ),
              ),
            ),
          ),

          // Top scrim so the HUD reads on bright scenes.
          const Positioned(
            left: 0, right: 0, top: 0, height: 88,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [Color(0x8C000000), Color(0x00000000)],
                  ),
                ),
              ),
            ),
          ),

          // ── Top HUD ────────────────────────────────────────────────────────
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic,
            left: contentLeft + S.md, right: S.md, top: S.md,
            child: _buildHud(),
          ),

          if (_showMetrics)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic,
              left: contentLeft + S.md, top: 56,
              child: MetricsOverlay(camera: _camera, status: _deviceStatus),
            ),

          // Reading text pushed from the desktop, under the tally.
          Consumer<ConnectionService>(
            builder: (_, conn, __) => conn.readingText.trim().isEmpty
                ? const SizedBox.shrink()
                : Positioned(
                    top: 56, left: contentLeft + 80, right: 96,
                    child: IgnorePointer(child: Center(child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(R.md)),
                      child: Text(conn.readingText, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: C.text, fontSize: 17, fontWeight: FontWeight.w700, height: 1.3)),
                    ))),
                  ),
          ),

          if (_smartMode && !_camera.smartZoomActive)
            Positioned(
              left: contentLeft + S.md, right: 84, bottom: 84,
              child: IgnorePointer(child: Center(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(color: const Color(0xD9000000), borderRadius: BorderRadius.circular(R.pill), border: Border.all(color: C.accent)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  PhosphorIcon(PhosphorIconsFill.handTap, color: C.accent, size: 18),
                  const SizedBox(width: 8),
                  const Flexible(child: Text('اضغط على الشخص لمتابعته  ·  Tap a person to follow',
                      style: T.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
              ))),
            ),

          // ── Right tool rail ────────────────────────────────────────────────
          // Scrolls rather than overflowing on short (landscape) screens.
          Positioned(right: S.md, top: 56, bottom: S.md, child: Center(child: SingleChildScrollView(child: _buildToolRail()))),

          // ── Bottom zoom dial ───────────────────────────────────────────────
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic,
            left: contentLeft, right: 76, bottom: S.md,
            child: Center(child: _buildZoomDial()),
          ),

          // Big transient zoom readout while pinching / scrubbing.
          if (_showZoomBar)
            Positioned(
              left: contentLeft, right: 0, top: 0, bottom: 0,
              child: IgnorePointer(child: Center(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(R.lg)),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('${_camera.zoom.toStringAsFixed(1)}×', style: T.zoom.copyWith(fontSize: 34)),
                  if (!_camera.hasHardwareZoom) const Text('DIGITAL', style: T.overline),
                ]),
              ))),
            ),

          // ── Side panel (tab content) ───────────────────────────────────────
          AnimatedPositioned(
            duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic,
            left: panelOpen ? _railW : _railW - panelW - 8,
            top: 0, bottom: 0, width: panelW,
            child: _buildPanel(),
          ),

          // ── Left tab rail ──────────────────────────────────────────────────
          Positioned(left: 0, top: 0, bottom: 0, width: _railW, child: _buildRail()),
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

  // ── Left rail (tabs) ────────────────────────────────────────────────────────
  Widget _buildRail() {
    Widget tab(_Tab t, IconData icon, IconData activeIcon, String label) {
      final on = _tab == t;
      return Semantics(
        button: true, selected: on, label: label,
        child: Tooltip(
          message: label,
          preferBelow: false,
          child: GestureDetector(
            onTap: () { HapticFeedback.selectionClick(); _openTab(t); },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 52, height: 52,
              margin: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                color: on ? C.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(R.md),
              ),
              child: PhosphorIcon(on ? activeIcon : icon, size: 24, color: on ? C.accentInk : C.textDim),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xF00D0D12),
        border: Border(right: BorderSide(color: C.hairline)),
      ),
      child: SafeArea(
        right: false,
        child: Column(children: [
          const SizedBox(height: S.md),
          // Viewfinder "home": closes any panel.
          Semantics(
            button: true, label: 'Viewfinder',
            child: GestureDetector(
              onTap: () => setState(() => _tab = null),
              child: Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(R.md),
                  border: Border.all(color: _tab == null ? C.accent : C.border, width: 1.5),
                ),
                child: PhosphorIcon(PhosphorIconsFill.aperture, color: _tab == null ? C.accent : C.textDim, size: 24),
              ),
            ),
          ),
          const SizedBox(height: S.md),
          Container(width: 28, height: 1, color: C.border),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: S.sm),
              child: Column(children: [
                tab(_Tab.live, PhosphorIconsRegular.broadcast, PhosphorIconsFill.broadcast, 'Live cameras'),
                tab(_Tab.smart, PhosphorIconsRegular.userFocus, PhosphorIconsFill.userFocus, 'Smart Zoom'),
                tab(_Tab.image, PhosphorIconsRegular.faders, PhosphorIconsFill.faders, 'Image & filters'),
                tab(_Tab.studio, PhosphorIconsRegular.projectorScreen, PhosphorIconsFill.projectorScreen, 'Studio control'),
              ]),
            ),
          ),
          tab(_Tab.settings, PhosphorIconsRegular.gearSix, PhosphorIconsFill.gearSix, 'Settings'),
          const SizedBox(height: S.md),
        ]),
      ),
    );
  }

  // ── Top HUD ─────────────────────────────────────────────────────────────────
  Widget _buildHud() {
    return Consumer<ConnectionService>(builder: (_, conn, __) {
      final connected = conn.status == ConnectionStatus.connected;
      final ms = conn.latencyMs;
      final linkColor = !connected ? C.tally : (ms < 60 ? C.ok : (ms <= 150 ? C.warn : C.tally));
      final linkText = connected ? '$ms ms' : (conn.status == ConnectionStatus.reconnecting ? 'Reconnecting' : 'Offline');

      final bars = _deviceStatus.wifiBars;
      final wifiIcon = _deviceStatus.wifiRssi <= -127 ? PhosphorIconsRegular.wifiSlash
          : bars >= 3 ? PhosphorIconsBold.wifiHigh
          : bars == 2 ? PhosphorIconsBold.wifiMedium
          : bars == 1 ? PhosphorIconsBold.wifiLow : PhosphorIconsBold.wifiNone;
      final bp = _deviceStatus.batteryPercent;
      final batIcon = _deviceStatus.charging ? PhosphorIconsBold.batteryCharging
          : bp < 0 ? PhosphorIconsBold.batteryMedium
          : bp > 80 ? PhosphorIconsBold.batteryFull
          : bp > 50 ? PhosphorIconsBold.batteryHigh
          : bp > 20 ? PhosphorIconsBold.batteryMedium
          : bp > 10 ? PhosphorIconsBold.batteryLow : PhosphorIconsBold.batteryWarning;
      final batColor = _deviceStatus.charging ? C.ok : (bp >= 0 && bp <= 15 ? C.tally : (bp >= 0 && bp <= 30 ? C.warn : C.text));

      final live = conn.isSelfLive;
      final lost = _camera.smartZoomActive && _camera.tracker.lost;

      return Row(children: [
        GestureDetector(
          onTap: () => setState(() => _showMetrics = !_showMetrics),
          child: Semantics(
            button: true, label: 'Connection $linkText. Tap for stream stats',
            child: HudChip(
              borderColor: linkColor.withValues(alpha: 0.6),
              child: Row(children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: linkColor, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text(linkText, style: T.hud.copyWith(color: linkColor)),
              ]),
            ),
          ),
        ),
        const SizedBox(width: S.sm),
        HudChip(child: Row(children: [
          PhosphorIcon(wifiIcon, size: 16, color: C.text),
          const SizedBox(width: 8),
          PhosphorIcon(batIcon, size: 18, color: batColor),
          if (bp >= 0) ...[const SizedBox(width: 4), Text('$bp%', style: T.hud.copyWith(color: batColor))],
        ])),
        const Spacer(),
        // Tally — the one thing an operator must read from across the room.
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: live ? C.tally : C.scrim,
            borderRadius: BorderRadius.circular(R.sm),
            border: Border.all(color: live ? C.tally : C.hairline),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            PhosphorIcon(live ? PhosphorIconsFill.record : PhosphorIconsRegular.record, size: 14, color: live ? Colors.white : C.textDim),
            const SizedBox(width: 6),
            Text(live ? 'ON AIR' : 'STANDBY',
                style: T.hud.copyWith(color: live ? Colors.white : C.textDim, letterSpacing: 1.4, fontWeight: FontWeight.w900)),
          ]),
        ),
        if (lost) ...[
          const SizedBox(width: S.sm),
          HudChip(
            borderColor: C.warn,
            child: Row(children: [
              PhosphorIcon(PhosphorIconsFill.warningCircle, size: 16, color: C.warn),
              const SizedBox(width: 6),
              Text('Subject lost', style: T.hud.copyWith(color: C.warn)),
            ]),
          ),
        ],
        const Spacer(),
        // Secondary info — dropped while a panel narrows the viewfinder, so the
        // link, battery and tally never get pushed off screen.
        if (_tab == null) ...[
          HudChip(child: Text(
            '${_camera.measuredFps > 0 ? _camera.measuredFps : _camera.targetFps} FPS  ·  ${_camera.isH264Mode ? 'H.264' : 'MJPEG'}',
            style: T.hud.copyWith(color: C.textDim),
          )),
          const SizedBox(width: 64), // keep clear of the tool rail column
        ],
      ]);
    });
  }

  // ── Right tool rail ─────────────────────────────────────────────────────────
  Widget _buildToolRail() {
    Widget lockBadge() => Container(
          width: 18, height: 18,
          decoration: BoxDecoration(color: C.bg, shape: BoxShape.circle, border: Border.all(color: C.warn, width: 1.5)),
          child: PhosphorIcon(PhosphorIconsFill.lockSimple, size: 10, color: C.warn),
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      ToolButton(
        icon: PhosphorIconsRegular.userFocus, activeIcon: PhosphorIconsFill.userFocus,
        label: _smartMode ? 'Smart Zoom on' : 'Smart Zoom',
        active: _smartMode, onTap: _toggleSmartMode,
      ),
      const SizedBox(height: S.sm),
      ToolButton(
        icon: PhosphorIconsRegular.crosshair, activeIcon: PhosphorIconsBold.crosshair,
        label: _camera.focusLocked ? 'Focus locked' : 'Lock focus',
        active: _camera.focusLocked, activeColor: C.warn,
        badge: _camera.focusLocked ? lockBadge() : null,
        onTap: () => _camera.setFocusLocked(!_camera.focusLocked),
      ),
      const SizedBox(height: S.sm),
      ToolButton(
        icon: PhosphorIconsRegular.sun, activeIcon: PhosphorIconsFill.sun,
        label: _camera.exposureLocked ? 'Exposure locked' : 'Lock exposure',
        active: _camera.exposureLocked, activeColor: C.warn,
        badge: _camera.exposureLocked ? lockBadge() : null,
        onTap: () => _camera.setExposureLocked(!_camera.exposureLocked),
      ),
      const SizedBox(height: S.sm),
      ToolButton(
        icon: PhosphorIconsRegular.lightningSlash, activeIcon: PhosphorIconsFill.lightning,
        label: _camera.torchOn ? 'Torch on' : 'Torch',
        active: _camera.torchOn, activeColor: C.warn,
        onTap: _camera.hasTorch ? () => _camera.toggleTorch() : null,
      ),
      const SizedBox(height: S.sm),
      ToolButton(
        icon: PhosphorIconsRegular.cameraRotate,
        label: 'Switch lens',
        onTap: () async {
          await _camera.switchCamera();
          if (mounted) setState(() => _smartMode = false);
          _conn?.sendCapabilities(_camera.capabilities());
          _reportPhoneState();
        },
      ),
    ]);
  }

  // ── Zoom dial ───────────────────────────────────────────────────────────────
  // Presets for one-tap framing, the live value in the middle, and the whole
  // pill doubles as a scrubber: drag sideways to zoom smoothly.
  Widget _buildZoomDial() {
    final zMin = _camera.minZoom;
    final zMax = _camera.maxZoom > zMin ? _camera.maxZoom : zMin + 1;
    final presets = <double>[1, 2, 3, 5].where((z) => z >= zMin - 0.01 && z <= zMax + 0.01).toList();
    final z = _camera.zoom;

    Widget preset(double p) {
      final on = (z - p).abs() < 0.05;
      return Semantics(
        button: true, selected: on, label: 'Zoom ${p.toStringAsFixed(0)} times',
        child: GestureDetector(
          onTap: () { HapticFeedback.selectionClick(); _animateZoom(p); },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 44, height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: on ? C.text : Colors.transparent, shape: BoxShape.circle),
            child: Text('${p.toStringAsFixed(0)}×', style: T.hud.copyWith(color: on ? C.accentInk : C.text, fontSize: 13)),
          ),
        ),
      );
    }

    return GestureDetector(
      onHorizontalDragStart: (_) => _baseZoom = _camera.zoom,
      onHorizontalDragUpdate: (d) {
        // ~260dp of drag sweeps the full range.
        _baseZoom = (_baseZoom + d.delta.dx * (zMax - zMin) / 260).clamp(zMin, zMax);
        _applyZoom(_baseZoom);
      },
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: const Color(0xB3000000),
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(color: C.hairline),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _dialIcon(PhosphorIconsBold.minus, 'Zoom out', () => _applyZoom(z - (zMax - zMin) / 10)),
          ...presets.map(preset),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: C.accentSoft, borderRadius: BorderRadius.circular(R.pill)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              PhosphorIcon(PhosphorIconsBold.magnifyingGlass, size: 14, color: C.accent),
              const SizedBox(width: 6),
              Text('${z.toStringAsFixed(1)}×', style: T.zoom.copyWith(color: C.accent)),
            ]),
          ),
          _dialIcon(PhosphorIconsBold.plus, 'Zoom in', () => _applyZoom(z + (zMax - zMin) / 10)),
        ]),
      ),
    );
  }

  Widget _dialIcon(IconData icon, String label, VoidCallback onTap) => Semantics(
        button: true, label: label,
        child: GestureDetector(
          onTap: () { HapticFeedback.selectionClick(); onTap(); },
          child: SizedBox(width: 44, height: 44, child: PhosphorIcon(icon, size: 18, color: C.text)),
        ),
      );

  // ── Side panel ──────────────────────────────────────────────────────────────
  Widget _buildPanel() {
    final t = _tab;
    late final IconData icon;
    late final String title;
    Widget body = const SizedBox.shrink();
    switch (t) {
      case _Tab.live:
        icon = PhosphorIconsFill.broadcast; title = 'Live cameras'; body = _livePanel();
      case _Tab.smart:
        icon = PhosphorIconsFill.userFocus; title = 'Smart Zoom'; body = _smartPanel();
      case _Tab.image:
        icon = PhosphorIconsFill.faders; title = 'Image'; body = _imagePanel();
      case _Tab.studio:
        icon = PhosphorIconsFill.projectorScreen; title = 'Studio'; body = const StudioPanel();
      case _Tab.settings:
        icon = PhosphorIconsFill.gearSix; title = 'Settings'; body = SettingsPanel(onDisconnect: _disconnect);
      case null:
        icon = PhosphorIconsFill.aperture; title = '';
    }
    return Material(
      color: C.surface,
      child: Container(
        decoration: const BoxDecoration(border: Border(right: BorderSide(color: C.hairline))),
        child: SafeArea(
          left: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(S.lg, S.md, S.sm, S.sm),
              child: Row(children: [
                PhosphorIcon(icon, size: 20, color: C.accent),
                const SizedBox(width: S.sm),
                Expanded(child: Text(title, style: T.title)),
                Semantics(
                  button: true, label: 'Close panel',
                  child: IconButton(
                    onPressed: () => setState(() => _tab = null),
                    icon: PhosphorIcon(PhosphorIconsBold.x, size: 18, color: C.textDim),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: ValueKey(t), // each tab opens at its top
                padding: const EdgeInsets.fromLTRB(S.lg, S.sm, S.lg, S.lg),
                child: body,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // Live: every camera the desktop can put on air (incl. this phone) + the cut.
  Widget _livePanel() {
    return Consumer<ConnectionService>(builder: (_, conn, __) {
      final cams = conn.desktopCameras;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PanelSection(
          title: 'Put on air',
          children: [
            if (cams.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: S.md),
                child: Text('Waiting for the desktop to list its cameras…', style: T.body),
              )
            else
              ...cams.map((c) {
                final live = conn.activeCameraId == c.id;
                final self = c.id == conn.selfCameraId;
                final icon = c.kind == 'ip' ? PhosphorIconsRegular.videoCamera
                    : (c.kind == 'mobile' || c.kind == 'webrtc') ? PhosphorIconsRegular.deviceMobileCamera
                    : PhosphorIconsRegular.webcam;
                return PanelTile(
                  icon: icon,
                  title: self ? 'This phone' : c.label,
                  subtitle: self ? c.label : _kindLabel(c.kind),
                  highlighted: live,
                  highlightColor: C.tally,
                  trailing: live
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: C.tally, borderRadius: BorderRadius.circular(R.sm)),
                          child: const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1)),
                        )
                      : PhosphorIcon(PhosphorIconsBold.caretRight, size: 16, color: C.textFaint),
                  onTap: live ? null : () => conn.selectDesktopCamera(c.id),
                );
              }),
          ],
        ),
        if (conn.transitions.isNotEmpty)
          PanelSection(
            title: 'Transition',
            children: [
              Wrap(spacing: S.sm, runSpacing: S.sm, children: conn.transitions.map((t) => Choice(
                    label: t.labelAr.isNotEmpty ? t.labelAr : t.label,
                    selected: conn.switchTransition == t.id,
                    onTap: () => conn.setSwitchTransition(t.id),
                  )).toList()),
            ],
          ),
      ]);
    });
  }

  String _kindLabel(String kind) => switch (kind) {
        'ip' => 'IP camera',
        'mobile' => 'Phone',
        'webrtc' => 'Phone (WebRTC)',
        _ => 'USB camera',
      };

  // Smart Zoom: arm, shot size, follow, release.
  Widget _smartPanel() {
    final f = _camera.framer;
    final active = _camera.smartZoomActive;
    final lost = active && _camera.tracker.lost;
    final statusColor = lost ? C.warn : (active ? C.ok : C.textFaint);
    final statusText = !_smartMode ? 'Off' : !active ? 'Tap a person on screen' : lost ? 'Subject lost — tap them again' : (f.follow ? 'Following' : 'Locked');
    const shots = [
      ('Wide', ShotSize.wide, PhosphorIconsRegular.usersThree),
      ('Medium', ShotSize.medium, PhosphorIconsRegular.user),
      ('Close', ShotSize.close, PhosphorIconsRegular.userFocus),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PanelTile(
        icon: PhosphorIconsFill.userFocus,
        title: 'Smart Zoom',
        subtitle: statusText,
        highlighted: _smartMode,
        trailing: Switch(value: _smartMode, onChanged: (_) => _toggleSmartMode()),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: S.xl, top: S.xs),
        child: Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
          const SizedBox(width: S.sm),
          const Expanded(child: Text('Frames and follows one person with smooth, operator-style moves.', style: T.body)),
        ]),
      ),
      PanelSection(
        title: 'Shot size',
        children: [
          Wrap(spacing: S.sm, runSpacing: S.sm, children: shots.map((s) => Choice(
                label: s.$1, icon: s.$3,
                selected: (f.shotZoom - s.$2).abs() < 0.01,
                onTap: () { _camera.smartSetShot(s.$2); setState(() {}); },
              )).toList()),
        ],
      ),
      PanelSection(
        title: 'Behaviour',
        children: [
          PanelTile(
            icon: PhosphorIconsRegular.personSimpleWalk,
            title: 'Follow movement',
            subtitle: f.follow ? 'Keeps the person framed as they move' : 'Holds the shot where you locked it',
            trailing: Switch(value: f.follow, onChanged: (v) { _camera.smartSetFollow(v); setState(() {}); }),
          ),
          PanelTile(
            icon: PhosphorIconsRegular.arrowsOutSimple,
            title: 'Release',
            subtitle: 'Glide back to the full picture',
            onTap: active ? () { _camera.smartRelease(); setState(() {}); } : null,
          ),
        ],
      ),
    ]);
  }

  // Image: looks + manual grading (applied to this phone's feed on the desktop).
  Widget _imagePanel() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PanelSection(
        title: 'Looks',
        children: [
          // 'Reset' is a duplicate of 'Natural' in the preset list — the Adjust
          // section has its own Reset, so it's left out here.
          Wrap(spacing: S.sm, runSpacing: S.sm, children: kFilterPresets.where((p) => p.name != 'Reset').map((p) => Choice(
                label: p.name,
                selected: _filters.toJson().toString() == p.filters.toJson().toString(),
                onTap: () => _setFilters(p.filters),
              )).toList()),
        ],
      ),
      PanelSection(
        title: 'Adjust',
        trailing: TextButton.icon(
          onPressed: () => _setFilters(CameraFilters.none),
          icon: PhosphorIcon(PhosphorIconsBold.arrowCounterClockwise, size: 14, color: C.accent),
          label: const Text('Reset', style: TextStyle(color: C.accent, fontWeight: FontWeight.w700)),
        ),
        children: [
          ValueSlider(icon: PhosphorIconsRegular.sun, label: 'Brightness', value: _filters.brightness, min: 0, max: 200, neutral: 100,
              format: (v) => v.round().toString(), onChanged: (v) => _setFilters(_filters.copyWith(brightness: v))),
          ValueSlider(icon: PhosphorIconsRegular.circleHalf, label: 'Contrast', value: _filters.contrast, min: 0, max: 200, neutral: 100,
              format: (v) => v.round().toString(), onChanged: (v) => _setFilters(_filters.copyWith(contrast: v))),
          ValueSlider(icon: PhosphorIconsRegular.drop, label: 'Saturation', value: _filters.saturation, min: 0, max: 200, neutral: 100,
              format: (v) => v.round().toString(), onChanged: (v) => _setFilters(_filters.copyWith(saturation: v))),
          ValueSlider(icon: PhosphorIconsRegular.dropHalfBottom, label: 'Blur', value: _filters.blur, min: 0, max: 10, neutral: 0,
              format: (v) => v.toStringAsFixed(1), onChanged: (v) => _setFilters(_filters.copyWith(blur: v))),
        ],
      ),
      PanelSection(
        title: 'Locks',
        children: [
          PanelTile(
            icon: PhosphorIconsRegular.crosshair, title: 'Focus lock',
            subtitle: _camera.focusLocked ? 'Holding focus distance' : 'Continuous autofocus',
            highlighted: _camera.focusLocked, highlightColor: C.warn,
            trailing: Switch(value: _camera.focusLocked, onChanged: (v) => _camera.setFocusLocked(v)),
          ),
          PanelTile(
            icon: PhosphorIconsRegular.sun, title: 'Exposure lock',
            subtitle: _camera.exposureLocked ? 'Holding brightness' : 'Auto exposure',
            highlighted: _camera.exposureLocked, highlightColor: C.warn,
            trailing: Switch(value: _camera.exposureLocked, onChanged: (v) => _camera.setExposureLocked(v)),
          ),
        ],
      ),
    ]);
  }

  void _disconnect() {
    context.read<ConnectionService>().disconnect();
    Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
  }

  // ── Full-screen states ──────────────────────────────────────────────────────
  Widget _startingView() => const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5, color: C.accent)),
          SizedBox(height: S.lg),
          Text('Starting camera…', style: T.label),
        ]),
      );

  Widget _stateView({required IconData icon, required Color color, required String title, required String body, required List<Widget> actions}) =>
      Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(S.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(R.lg)),
              child: PhosphorIcon(icon, size: 32, color: color),
            ),
            const SizedBox(height: S.lg),
            Text(title, style: T.title.copyWith(fontSize: 20), textAlign: TextAlign.center),
            const SizedBox(height: S.sm),
            Text(body, style: T.body, textAlign: TextAlign.center),
            const SizedBox(height: S.xl),
            Wrap(spacing: S.md, runSpacing: S.sm, alignment: WrapAlignment.center, children: actions),
          ]),
        ),
      ));

  Widget _permissionDeniedView() => _stateView(
        icon: PhosphorIconsFill.cameraSlash, color: C.warn,
        title: 'Camera access needed',
        body: 'Church Cam needs the camera to stream this phone to the desktop studio.',
        actions: [
          FilledButton.icon(onPressed: openCameraSettings, icon: PhosphorIcon(PhosphorIconsBold.gearSix, size: 16, color: C.accentInk), label: const Text('Open settings')),
          TextButton(onPressed: _disconnect, child: const Text('Back')),
        ],
      );

  Widget _errorView(String message) => _stateView(
        icon: PhosphorIconsFill.warningCircle, color: C.tally,
        title: 'Camera unavailable',
        body: message,
        actions: [FilledButton(onPressed: _disconnect, child: const Text('Back to connections'))],
      );
}

enum _Tab { live, smart, image, studio, settings }

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
  const _FocusRing();

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
        // Square AF bracket (camera-native), not a generic circle.
        child: Container(
          width: 72, height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(R.sm),
            border: Border.all(color: C.warn, width: 1.5),
          ),
          child: Center(child: Container(width: 4, height: 4, decoration: const BoxDecoration(color: C.warn, shape: BoxShape.circle))),
        ),
      );
}
