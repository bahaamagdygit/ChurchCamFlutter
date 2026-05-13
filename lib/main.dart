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
  late ConnectionService _connectionService;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  void _initializeServices() {
    try {
      _connectionService = ConnectionService();
      if (mounted) {
        setState(() {
          _initError = null;
        });
      }
    } catch (e) {
      print('Service init error: $e');
      if (mounted) {
        setState(() {
          _initError = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Text('Initialization Error:\n$_initError'),
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
      value: _connectionService,
      child: const ConnectScreen(),
    );
  }
}
