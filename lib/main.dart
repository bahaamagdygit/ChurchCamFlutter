import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/connection_service.dart';
import 'screens/connect_screen.dart';
import 'screens/camera_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Church Cam',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late ConnectionService _connectionService;
  bool _isReady = false;
  String _statusMessage = 'Loading...';

  @override
  void initState() {
    super.initState();
    _setupApp();
  }

  void _setupApp() async {
    try {
      await Future.delayed(const Duration(seconds: 1));

      if (!mounted) return;

      final service = ConnectionService();

      setState(() {
        _connectionService = service;
        _isReady = true;
        _statusMessage = 'Ready';
      });
    } catch (e) {
      setState(() {
        _statusMessage = 'Error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady) {
      return Scaffold(
        appBar: AppBar(title: const Text('Church Cam')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_statusMessage),
            ],
          ),
        ),
      );
    }

    return ChangeNotifierProvider<ConnectionService>.value(
      value: _connectionService,
      child: const ConnectScreen(),
    );
  }
}
