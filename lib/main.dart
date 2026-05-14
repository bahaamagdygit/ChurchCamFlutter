import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/connection_service.dart';
import 'screens/connect_screen.dart';
import 'screens/camera_screen.dart';

void main() {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    print('FLUTTER ERROR: ${details.exception}');
    print('STACK: ${details.stack}');
  };

  runZonedGuarded(() {
    runApp(const MyApp());
  }, (Object error, StackTrace stackTrace) {
    print('ZONE ERROR: $error');
    print('STACK: $stackTrace');
  });
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Church Cam',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const SafeApp(),
      routes: {
        '/camera': (context) => const CameraScreen(),
      },
      builder: (context, home) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaleFactor: 1.0),
          child: home ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

class SafeApp extends StatefulWidget {
  const SafeApp({Key? key}) : super(key: key);

  @override
  State<SafeApp> createState() => _SafeAppState();
}

class _SafeAppState extends State<SafeApp> {
  ConnectionService? _connectionService;
  String? _initError;
  bool _isInitializing = true;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  void _initializeServices() {
    if (mounted) {
      setState(() {
        _isInitializing = true;
        _initError = null;
      });
    }

    Future.delayed(Duration(milliseconds: 500), () {
      try {
        final service = ConnectionService();
        if (mounted) {
          setState(() {
            _connectionService = service;
            _isInitializing = false;
            _initError = null;
          });
        }
      } catch (e) {
        print('Service init error: $e');
        print('Stack trace: ${StackTrace.current}');
        if (mounted) {
          setState(() {
            _connectionService = null;
            _isInitializing = false;
            _initError = 'Failed to initialize: $e';
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              const Text('Initializing Church Cam...'),
            ],
          ),
        ),
      );
    }

    if (_initError != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Initialization Error:\n$_initError',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _initializeServices,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_connectionService == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.warning, color: Colors.orange, size: 48),
              const SizedBox(height: 16),
              const Text('Connection Service Not Available'),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _initializeServices,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return ChangeNotifierProvider<ConnectionService>.value(
      value: _connectionService!,
      child: const ConnectScreen(),
    );
  }
}
