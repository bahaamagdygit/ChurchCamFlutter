import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({Key? key}) : super(key: key);

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _controlPortController = TextEditingController();
  final TextEditingController _videoPortController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _hostController.text = '10.0.0.69';
    _controlPortController.text = '8765';
    _videoPortController.text = '8766';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Church Cam - Connect'),
      ),
      body: Consumer<ConnectionService>(
        builder: (context, connectionService, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 32),
                const Text(
                  'Connect to Desktop',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _hostController,
                  decoration: InputDecoration(
                    labelText: 'Host IP',
                    hintText: '10.0.0.69',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  enabled: connectionService.status == ConnectionStatus.idle,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _controlPortController,
                  decoration: InputDecoration(
                    labelText: 'Control Port',
                    hintText: '8765',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  keyboardType: TextInputType.number,
                  enabled: connectionService.status == ConnectionStatus.idle,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _videoPortController,
                  decoration: InputDecoration(
                    labelText: 'Video Port',
                    hintText: '8766',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  keyboardType: TextInputType.number,
                  enabled: connectionService.status == ConnectionStatus.idle,
                ),
                const SizedBox(height: 32),
                _buildStatusWidget(connectionService),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _handleConnect(connectionService),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor:
                        connectionService.status == ConnectionStatus.connecting
                            ? Colors.grey
                            : Colors.blue,
                  ),
                  child: Text(
                    connectionService.status == ConnectionStatus.connecting
                        ? 'Connecting...'
                        : connectionService.status == ConnectionStatus.connected
                            ? 'Go to Camera'
                            : 'Connect',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
                const SizedBox(height: 16),
                if (connectionService.status == ConnectionStatus.error)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.red.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Connection Error',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.red,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Make sure:\n'
                          '• Both devices are on the same WiFi\n'
                          '• Desktop app is running\n'
                          '• IP address is correct\n'
                          '• Ports 8765 & 8766 are accessible',
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatusWidget(ConnectionService connectionService) {
    final status = connectionService.status;
    final color = status == ConnectionStatus.connected
        ? Colors.green
        : status == ConnectionStatus.error
            ? Colors.red
            : status == ConnectionStatus.connecting
                ? Colors.orange
                : Colors.grey;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _statusText(status),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          if (status == ConnectionStatus.connected)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Latency: ${connectionService.latencyMs}ms',
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  String _statusText(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.idle:
        return 'Disconnected';
      case ConnectionStatus.connecting:
        return 'Connecting...';
      case ConnectionStatus.connected:
        return 'Connected';
      case ConnectionStatus.error:
        return 'Connection Error';
      case ConnectionStatus.reconnecting:
        return 'Reconnecting...';
    }
  }

  VoidCallback? _handleConnect(ConnectionService connectionService) {
    if (connectionService.status == ConnectionStatus.connecting) {
      return null;
    }

    if (connectionService.status == ConnectionStatus.connected) {
      return () {
        try {
          Navigator.of(context).pushNamed('/camera');
        } catch (e) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Navigation error: $e')),
          );
        }
      };
    }

    return () async {
      try {
        final host = _hostController.text;
        final controlPort = int.tryParse(_controlPortController.text) ?? 8765;
        final videoPort = int.tryParse(_videoPortController.text) ?? 8766;

        if (host.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please enter host IP')),
          );
          return;
        }

        final success = await connectionService.connect(host, controlPort, videoPort);
        if (success && mounted) {
          Navigator.of(context).pushNamed('/camera');
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Connection error: $e')),
          );
        }
      }
    };
  }

  @override
  void dispose() {
    _hostController.dispose();
    _controlPortController.dispose();
    _videoPortController.dispose();
    super.dispose();
  }
}
