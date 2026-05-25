import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({Key? key}) : super(key: key);

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  void _disconnect() {
    try {
      context.read<ConnectionService>().disconnect();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      print('Disconnect error: $e');
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
        ),
        body: Consumer<ConnectionService>(
          builder: (context, connectionService, _) {
            return Column(
              children: [
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
                                  : Colors.red,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            connectionService.status ==
                                    ConnectionStatus.connected
                                ? 'Live · ${connectionService.latencyMs}ms'
                                : 'Offline',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'Connected',
                          style: TextStyle(fontSize: 24),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Sent: ${connectionService.framesSent}',
                          style: const TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 32),
                        ElevatedButton(
                          onPressed: _disconnect,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                          ),
                          child: const Text('Disconnect'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
