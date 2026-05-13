import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:camera/camera.dart';
import '../services/connection_service.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({Key? key}) : super(key: key);

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _cameraController;
  late List<CameraDescription> cameras;
  bool _isCameraInitialized = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      if (mounted) {
        setState(() {
          _errorMessage = null;
        });
      }

      cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('No cameras available on this device');
      }

      _cameraController = CameraController(
        cameras[0],
        ResolutionPreset.high,
        enableAudio: true,
      );

      await _cameraController!.initialize();

      if (mounted) {
        setState(() {
          _isCameraInitialized = true;
        });
      }
    } on CameraException catch (e) {
      String errorMsg = 'Camera Error: ${e.code}\n${e.description}';
      if (e.code == 'CameraAccessDenied') {
        errorMsg = 'Camera access denied.\nGrant permission in app settings.';
      }
      _handleError(errorMsg);
    } catch (e) {
      _handleError('Failed to initialize camera: $e');
    }
  }

  void _handleError(String message) {
    if (mounted) {
      setState(() {
        _errorMessage = message;
        _isCameraInitialized = false;
      });
    }
  }

  void _disconnect() {
    try {
      context.read<ConnectionService>().disconnect();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Disconnect error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        _disconnect();
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Church Cam - Live'),
          automaticallyImplyLeading: true,
        ),
        body: Consumer<ConnectionService>(
          builder: (context, connectionService, _) {
            return Column(
              children: [
                // Status bar
                Container(
                  color: Colors.grey[900],
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: connectionService.status ==
                                      ConnectionStatus.connected
                                  ? Colors.green
                                  : connectionService.status ==
                                          ConnectionStatus.reconnecting
                                      ? Colors.orange
                                      : Colors.red,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            connectionService.status ==
                                    ConnectionStatus.connected
                                ? 'Live · ${connectionService.latencyMs}ms'
                                : connectionService.status ==
                                        ConnectionStatus.reconnecting
                                    ? 'Reconnecting...'
                                    : 'Offline',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: _isCameraInitialized
                                ? Colors.green
                                : Colors.red,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _isCameraInitialized ? '📷 ON' : '📷 OFF',
                          style: TextStyle(
                            color: _isCameraInitialized
                                ? Colors.green
                                : Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Frame stats
                Container(
                  color: Colors.grey[800],
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    'sent ${connectionService.framesSent} · dropped ${connectionService.framesDropped}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                // Camera preview or error
                Expanded(
                  child: _errorMessage != null
                      ? _buildErrorWidget()
                      : _isCameraInitialized && _cameraController != null
                          ? _buildCameraWidget(connectionService)
                          : _buildLoadingWidget(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildErrorWidget() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 48),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              _errorMessage ?? 'Unknown error',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.red),
            ),
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: _initializeCamera,
            child: const Text('Retry'),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _disconnect,
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Go Back'),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraWidget(ConnectionService connectionService) {
    return Stack(
      children: [
        CameraPreview(_cameraController!),
        Positioned(
          bottom: 16,
          left: 16,
          right: 16,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ElevatedButton(
              onPressed: _disconnect,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Disconnect'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingWidget() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          const Text('Initializing camera...'),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: _disconnect,
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Go Back'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    try {
      _cameraController?.dispose();
    } catch (e) {
      print('Error disposing camera: $e');
    }
    super.dispose();
  }
}
