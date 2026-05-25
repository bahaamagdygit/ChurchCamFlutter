import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/connection_service.dart';
import '../services/camera_service.dart';
import '../utils/permissions.dart';
import '../widgets/reading_overlay.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  final CameraService _camera = CameraService();

  bool _permissionDenied = false;
  bool _initializing = true;
  String? _initError;

  // Pinch-to-zoom state
  double _baseZoom = 1.0;
  bool _showZoomBar = false;

  ConnectionService? _conn;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _conn = context.read<ConnectionService>();
    _conn!.addCommandListener(_onRemoteCommand);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final granted = await requestCameraPermission();
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _permissionDenied = true;
        _initializing = false;
      });
      return;
    }

    final ok = await _camera.initialize();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _initError = 'No camera available on this device.';
        _initializing = false;
      });
      return;
    }

    // Advertise zoom/torch capabilities so the desktop slider has the right range.
    _conn?.sendCapabilities(_camera.capabilities());

    // Pipe encoded JPEG frames straight to the video socket.
    _camera.onJpegFrame = (jpeg) => _conn?.sendFrame(jpeg);
    await _camera.startStreaming();

    _camera.addListener(_onCameraChanged);
    if (mounted) setState(() => _initializing = false);
  }

  void _onCameraChanged() {
    if (mounted) setState(() {});
  }

  /// Commands pushed from the desktop operator.
  void _onRemoteCommand(RemoteCommand cmd) {
    switch (cmd.action) {
      case 'set_zoom':
      case 'zoom':
        final v = cmd.value;
        if (v is num) _applyZoom(v.toDouble());
        break;
      case 'flip':
      case 'switch_camera':
        _camera.switchCamera();
        break;
      case 'torch':
      case 'toggle_torch':
        _camera.toggleTorch();
        break;
    }
  }

  Future<void> _applyZoom(double z) async {
    await _camera.setZoom(z);
    _showZoomIndicator();
  }

  void _showZoomIndicator() {
    setState(() => _showZoomBar = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showZoomBar = false);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause/resume capture with app lifecycle to free the camera cleanly.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _camera.stopStreaming();
    } else if (state == AppLifecycleState.resumed) {
      if (_camera.isInitialized) _camera.startStreaming();
    }
  }

  void _disconnect() {
    context.read<ConnectionService>().disconnect();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _conn?.removeCommandListener(_onRemoteCommand);
    _camera.removeListener(_onCameraChanged);
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _disconnect();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_permissionDenied) return _permissionDeniedView();
    if (_initError != null) return _errorView(_initError!);
    if (_initializing || !_camera.isInitialized) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text('Starting camera…', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Live preview, fills the screen with a centered cover crop.
        GestureDetector(
          onScaleStart: (_) => _baseZoom = _camera.zoom,
          onScaleUpdate: (d) {
            if (d.scale == 1.0) return;
            _applyZoom(_baseZoom * d.scale);
          },
          child: _buildPreview(),
        ),

        _buildTopBar(),
        if (_showZoomBar) _buildZoomBar(),
        _buildControls(),

        Consumer<ConnectionService>(
          builder: (_, conn, __) => ReadingOverlay(text: conn.readingText),
        ),
      ],
    );
  }

  Widget _buildPreview() {
    final controller = _camera.controller!;
    // Cover the full screen without distortion.
    final size = MediaQuery.of(context).size;
    return ClipRect(
      child: OverflowBox(
        maxWidth: double.infinity,
        maxHeight: double.infinity,
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

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 48, 14, 12),
        color: Colors.black54,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _circleButton(Icons.close, _disconnect),
            Consumer<ConnectionService>(
              builder: (_, conn, __) {
                final connected = conn.status == ConnectionStatus.connected;
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: connected ? Colors.green : Colors.red,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (connected)
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(right: 6),
                          decoration: const BoxDecoration(
                            color: Colors.green, shape: BoxShape.circle),
                        ),
                      Text(
                        connected
                            ? '● Live · ${conn.latencyMs}ms'
                            : conn.status == ConnectionStatus.reconnecting
                                ? 'Reconnecting…'
                                : 'Offline',
                        style: TextStyle(
                          color: connected ? Colors.green : Colors.red,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            _circleButton(
              _camera.torchOn ? Icons.flash_on : Icons.flash_off,
              _camera.hasTorch ? _camera.toggleTorch : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildZoomBar() {
    final pct = _camera.maxZoom > _camera.minZoom
        ? (_camera.zoom - _camera.minZoom) /
            (_camera.maxZoom - _camera.minZoom)
        : 0.0;
    return Positioned(
      bottom: 150,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xCC000000),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0x66818CF8)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 100,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: pct.clamp(0.0, 1.0),
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF818CF8)),
                    minHeight: 4,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${_camera.zoom.toStringAsFixed(1)}×',
                style: const TextStyle(
                  color: Color(0xFF818CF8),
                  fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        color: Colors.black54,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _controlButton(Icons.cameraswitch, 'Flip',
                () { _applyZoom(1.0); _camera.switchCamera(); }),
            _controlButton(Icons.zoom_out, 'Zoom −',
                () => _applyZoom(_camera.zoom - 0.5)),
            _zoomBadge(),
            _controlButton(Icons.zoom_in, 'Zoom +',
                () => _applyZoom(_camera.zoom + 0.5)),
            _facingBadge(),
          ],
        ),
      ),
    );
  }

  Widget _zoomBadge() {
    return GestureDetector(
      onTap: () => _applyZoom(1.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0x33818CF8),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF818CF8), width: 1.5),
        ),
        child: Text(
          '${_camera.zoom.toStringAsFixed(1)}×',
          style: const TextStyle(
            color: Color(0xFF818CF8), fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _facingBadge() {
    final isFront = _camera.lensDirection == CameraLensDirection.front;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(isFront ? Icons.person : Icons.camera_rear, color: Colors.white70),
        const SizedBox(height: 4),
        Text(isFront ? 'Front' : 'Back',
            style: const TextStyle(color: Colors.white54, fontSize: 10)),
      ],
    );
  }

  Widget _controlButton(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xD91E1E32),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24),
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(height: 5),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _circleButton(IconData icon, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: const Color(0xBF141423),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24),
        ),
        child: Icon(icon,
            color: onTap == null ? Colors.white30 : Colors.white, size: 20),
      ),
    );
  }

  Widget _permissionDeniedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.camera_alt, color: Colors.white54, size: 64),
            const SizedBox(height: 20),
            const Text('Camera Permission Required',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            const Text(
              'Church Cam needs camera access to stream video to the desktop.',
              style: TextStyle(color: Colors.white60),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: openCameraSettings,
              child: const Text('Open Settings'),
            ),
            TextButton(
              onPressed: _disconnect,
              child: const Text('← Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorView(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 64),
            const SizedBox(height: 20),
            Text(message,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: _disconnect, child: const Text('← Back')),
          ],
        ),
      ),
    );
  }
}
