import 'package:flutter/material.dart';

/// Design tokens for the camera app. One small palette, one accent.
///
/// The look is a broadcast camera, not a consumer app: near-black surfaces so
/// the picture is the brightest thing on screen, one indigo accent (shared with
/// the desktop studio) for "selected / on", and colour reserved for meaning —
/// red is ONLY the on-air tally, amber is ONLY "locked / attention", green is
/// ONLY "healthy / tracking".
class C {
  // Surfaces
  static const bg = Color(0xFF09090D);
  static const surface = Color(0xF2121218);      // panels over the viewfinder
  static const surface2 = Color(0xFF1B1B24);     // controls inside panels
  static const surface3 = Color(0xFF262632);     // pressed / hover
  static const scrim = Color(0x99000000);        // over-video chrome
  static const border = Color(0xFF2A2A37);
  static const hairline = Color(0x1FFFFFFF);

  // Text
  static const text = Color(0xFFF3F3F7);
  static const textDim = Color(0xFFA3A3B5);      // 7.4:1 on surface
  static const textFaint = Color(0xFF6E6E82);

  // Meaning
  static const accent = Color(0xFF8B93FA);
  static const accentInk = Color(0xFF0B0B14);    // text on accent
  static const accentSoft = Color(0x2E8B93FA);
  static const tally = Color(0xFFFF3B30);
  static const warn = Color(0xFFFFB020);
  static const ok = Color(0xFF34D399);
}

class S {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;

  /// Minimum touch target.
  static const touch = 48.0;
}

class R {
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const pill = 999.0;
}

class T {
  static const _tab = [FontFeature.tabularFigures()];

  static const title = TextStyle(color: C.text, fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: -0.2);
  static const label = TextStyle(color: C.text, fontSize: 14, fontWeight: FontWeight.w600);
  static const body = TextStyle(color: C.textDim, fontSize: 13, height: 1.35);
  static const caption = TextStyle(color: C.textDim, fontSize: 12, fontWeight: FontWeight.w500);
  static const overline = TextStyle(color: C.textFaint, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.1);
  static const hud = TextStyle(color: C.text, fontSize: 12, fontWeight: FontWeight.w700, fontFeatures: _tab);
  static const zoom = TextStyle(color: C.text, fontSize: 15, fontWeight: FontWeight.w800, fontFeatures: _tab);
}

ThemeData buildAppTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: C.bg,
    colorScheme: const ColorScheme.dark(
      primary: C.accent,
      onPrimary: C.accentInk,
      secondary: C.accent,
      surface: C.surface2,
      onSurface: C.text,
      error: C.tally,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Color(0xFF15151C),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(R.lg))),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: C.surface3,
      contentTextStyle: TextStyle(color: C.text),
      behavior: SnackBarBehavior.floating,
    ),
    sliderTheme: const SliderThemeData(
      activeTrackColor: C.accent,
      inactiveTrackColor: C.border,
      thumbColor: C.text,
      overlayColor: C.accentSoft,
      trackHeight: 3,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.accentInk : C.textDim),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.accent : C.surface3),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.surface2,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      hintStyle: const TextStyle(color: C.textFaint),
      labelStyle: const TextStyle(color: C.textDim),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.md), borderSide: const BorderSide(color: C.accent, width: 1.5)),
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(color: C.surface3, borderRadius: BorderRadius.all(Radius.circular(R.sm))),
      textStyle: TextStyle(color: C.text, fontSize: 12),
    ),
  );
}
