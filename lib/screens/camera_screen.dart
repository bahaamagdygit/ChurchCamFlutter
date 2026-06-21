import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/connection_service.dart';
import '../services/camera_service.dart';
import '../services/abr_controller.dart';
import '../services/orientation_service.dart';
import '../services/storage.dart';
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

  bool _permissionDenied = false;
  bool _initializing = true;
  String? _initError;

  CameraFilters _filters = CameraFilters.none;
  bool _showFilters = false;

  // Pinch-to-zoom
  double _baseZoom = 1.0;
  bool _showZoomBar = false;

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
    // mode (default 720p; the ABR controller raises/lowers this live).
    if (_conn?.videoCodec == 'h264') {
      // Start at the top tier (1080p30) for maximum quality on capable devices;
      // the ABR controller steps down only if the link can't sustain it.
      await _camera.setH264Mode(true, width: 1920, height: 1080, bitrate: 6000000);
      _abr = AbrController(
        startTier: 0, // 1080p30
        onTierChange: (t) async {
          // Resolution/fps change → restart the encoder at the new tier.
          await _camera.setH264Mode(true, width: t.width, height: t.height, bitrate: t.bitrate);
          await _camera.requestH264Keyframe();
        },
        onBitrate: (br) => _camera.updateH264Bitrate(br),
      );
    }
    // On every (re)connect of the video socket, force a fresh config+keyframe so
    // the desktop decoder can initialize without a stall.
    _conn?.onVideoReady = () => _camera.requestH264Keyframe();

    await _camera.startStreaming();
    _camera.addListener(_onCameraChanged);

    // Adaptive-quality tick: h264 drives the ABR ladder; mjpeg uses the legacy
    // per-frame quality nudge. Runs every 1s for ABR / 500ms for mjpeg backlog.
    _adaptiveTimer = Timer.periodic(const Duration(milliseconds: 1000), (_) {
      final abr = _abr;
      if (abr != null && _camera.isH264Mode) {
        abr.tick(pendingBytes: _conn?.pendingVideoBytes ?? 0, targetFps: _camera.targetFps);
      } else {
        _camera.reportBacklog(_conn?.pendingVideoBytes ?? 0);
      }
    });

    if (mounted) setState(() => _initializing = false);
  }

  Map<String, dynamic> _buildStateRestore() => {
        'capabilities': _camera.capabilities(),
        'orientationAngle': _orientation.angle,
        'zoom': _camera.zoom,
        'filters': _filters.toJson(),
      };

  void _onCameraChanged() { if (mounted) setState(() {}); }

  void _onOrientation() {
    _conn?.sendOrientationAngle(_orientation.angle);
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
          await _camera.setZoom((cmd.value as num).toDouble());
          conn?.confirmControl('zoom', _camera.zoom);
          _showZoomIndicator();
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
        if (cmd.value is num) {
          final applied = await _camera.setExposure((cmd.value as num).toDouble());
          conn?.confirmControl('exposure', applied);
        }
        break;
      case 'white_balance':
        if (_camera.whiteBalanceSupported) {
          conn?.confirmControl('white_balance', cmd.value);
        } else {
          conn?.reportUnsupported('white_balance', 'not supported on this device');
        }
        break;
      case 'torch':
      case 'toggle_torch':
        await _camera.toggleTorch();
        conn?.confirmControl('torch', _camera.torchOn ? 'on' : 'off');
        break;
      case 'flip':
      case 'switch_camera':
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
    }
  }

  // ── Local filter change → push to desktop + persist ──────────────────────────
  Future<void> _setFilters(CameraFilters f) async {
    setState(() => _filters = f);
    await saveFilters(_camera.lensDirection.name, f);
    _conn?.sendControl('filters', f.toJson());
  }

  Future<void> _applyZoom(double z) async {
    await _camera.setZoom(z);
    _conn?.desktopZoom(_camera.zoom); // keep desktop software-zoom in sync
    _showZoomIndicator();
  }

  void _showZoomIndicator() {
    setState(() => _showZoomBar = true);
    Future.delayed(const Duration(seconds: 2), () { if (mounted) setState(() => _showZoomBar = false); });
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
    _focusTimer?.cancel();
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
            onScaleStart: (_) => _baseZoom = _camera.zoom,
            onScaleUpdate: (d) { if (d.scale != 1.0) _applyZoom(_baseZoom * d.scale); },
            onTapDown: (d) => _tapFocus(d, size),
            child: FilteredPreview(filters: _filters, child: _buildPreview()),
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
            Positioned(top: 84, left: 16, child: MetricsOverlay(camera: _camera)),

          // Torch + flip quick toggles (top-right)
          Positioned(top: 40, right: 12, child: Row(children: [
            _circle(_camera.torchOn ? Icons.flash_on : Icons.flash_off,
                _camera.hasTorch ? () => _camera.toggleTorch() : null),
            const SizedBox(width: 8),
            _circle(Icons.cameraswitch, () { _applyZoom(1.0); _camera.switchCamera(); }),
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
    final size = MediaQuery.of(context).size;
    return ClipRect(
      child: OverflowBox(
        maxWidth: double.infinity, maxHeight: double.infinity,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: size.width,
            height: size.width * controller.value.aspectRatio,
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
        ]),
      )),
    );
  }

  Widget _buildBottomPanel() {
    return Positioned(
      bottom: 0, left: 0, right: 0,
      child: Container(
        color: const Color(0x99000000),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 30),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header row: zoom slider + filters toggle
          Row(children: [
            const Icon(Icons.zoom_in, color: Colors.white54, size: 18),
            Expanded(child: Slider(
              value: _camera.zoom.clamp(_camera.minZoom, _camera.maxZoom),
              min: _camera.minZoom, max: _camera.maxZoom == _camera.minZoom ? _camera.minZoom + 1 : _camera.maxZoom,
              activeColor: _purple,
              onChanged: (v) => _applyZoom(v),
            )),
            IconButton(
              icon: Icon(Icons.auto_awesome, color: _showFilters ? _purple : Colors.white70),
              onPressed: () => setState(() => _showFilters = !_showFilters),
            ),
          ]),

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
