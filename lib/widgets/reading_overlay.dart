import 'package:flutter/material.dart';

/// Bottom overlay that shows the reading text the desktop operator pushes
/// (e.g. the current scripture line) so the person holding the phone can read.
class ReadingOverlay extends StatelessWidget {
  final String text;
  const ReadingOverlay({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Color(0xCC000000)],
            ),
          ),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              height: 1.3,
              shadows: [
                Shadow(blurRadius: 6, color: Colors.black, offset: Offset(0, 1)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
