import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/connection_service.dart';
import 'screens/connect_screen.dart';
import 'screens/home_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ChurchCamApp());
}

class ChurchCamApp extends StatelessWidget {
  const ChurchCamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ConnectionService(),
      child: MaterialApp(
        title: 'Church Cam',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4F46E5),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        initialRoute: '/',
        routes: {
          '/': (_) => const ConnectScreen(),
          '/home': (_) => const HomeShell(),
        },
      ),
    );
  }
}
