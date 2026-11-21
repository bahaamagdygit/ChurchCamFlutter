import 'package:flutter/material.dart';
import '../ui/tokens.dart';
import 'camera_screen.dart';

/// Shown after connecting. The camera screen owns the whole display: its left
/// icon rail holds the tabs (Live · Smart · Image · Studio · Settings), so the
/// old bottom navigation bar — which cost ~20% of a landscape viewfinder — is
/// gone, and the camera keeps streaming no matter which tab is open.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        backgroundColor: C.bg,
        resizeToAvoidBottomInset: false,
        body: CameraScreen(),
      );
}
