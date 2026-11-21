import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'services/connection_service.dart';
import 'screens/connect_screen.dart';
import 'screens/home_shell.dart';
import 'ui/tokens.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // LANDSCAPE LOCK: the app runs horizontal at all times (studio camera use).
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  // Immersive full-screen so the camera preview uses the whole display.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
        theme: buildAppTheme(),
        initialRoute: '/',
        routes: {
          '/': (_) => const ConnectScreen(),
          '/home': (_) => const HomeShell(),
        },
      ),
    );
  }
}
