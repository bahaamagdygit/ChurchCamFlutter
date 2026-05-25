import 'dart:math' as math;
import 'dart:ui';

/// The eight visual filter parameters applied to the camera preview overlay.
/// Ranges match the spec (Section 8).
class CameraFilters {
  final double brightness; // 0-200 %, default 100
  final double contrast;   // 0-200 %, default 100
  final double saturation; // 0-200 %, default 100
  final double hue;        // 0-360 deg, default 0
  final double sepia;      // 0-100 %, default 0
  final double grayscale;  // 0-100 %, default 0
  final double blur;       // 0-10 px, default 0
  final double opacity;    // 0-100 %, default 100

  const CameraFilters({
    this.brightness = 100,
    this.contrast = 100,
    this.saturation = 100,
    this.hue = 0,
    this.sepia = 0,
    this.grayscale = 0,
    this.blur = 0,
    this.opacity = 100,
  });

  static const CameraFilters none = CameraFilters();

  CameraFilters copyWith({
    double? brightness, double? contrast, double? saturation, double? hue,
    double? sepia, double? grayscale, double? blur, double? opacity,
  }) => CameraFilters(
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        hue: hue ?? this.hue,
        sepia: sepia ?? this.sepia,
        grayscale: grayscale ?? this.grayscale,
        blur: blur ?? this.blur,
        opacity: opacity ?? this.opacity,
      );

  Map<String, dynamic> toJson() => {
        'brightness': brightness, 'contrast': contrast, 'saturation': saturation,
        'hue': hue, 'sepia': sepia, 'grayscale': grayscale, 'blur': blur, 'opacity': opacity,
      };

  factory CameraFilters.fromJson(Map j) {
    double d(String k, double def) => (j[k] is num) ? (j[k] as num).toDouble() : def;
    return CameraFilters(
      brightness: d('brightness', 100), contrast: d('contrast', 100),
      saturation: d('saturation', 100), hue: d('hue', 0),
      sepia: d('sepia', 0), grayscale: d('grayscale', 0),
      blur: d('blur', 0), opacity: d('opacity', 100),
    );
  }

  bool get isIdentity =>
      brightness == 100 && contrast == 100 && saturation == 100 && hue == 0 &&
      sepia == 0 && grayscale == 0 && blur == 0 && opacity == 100;

  /// Build the 4x5 color matrix (20 values) combining brightness, contrast,
  /// saturation, hue rotation, sepia and grayscale.
  List<double> colorMatrix() {
    var m = _identity();
    // Brightness: scale RGB. (100% -> 1.0)
    final b = brightness / 100.0;
    m = _multiply(m, [
      b, 0, 0, 0, 0,
      0, b, 0, 0, 0,
      0, 0, b, 0, 0,
      0, 0, 0, 1, 0,
    ]);
    // Contrast: c around mid-gray. (100% -> 1.0)
    final c = contrast / 100.0;
    final t = (1.0 - c) * 0.5 * 255.0;
    m = _multiply(m, [
      c, 0, 0, 0, t,
      0, c, 0, 0, t,
      0, 0, c, 0, t,
      0, 0, 0, 1, 0,
    ]);
    // Saturation. (100% -> 1.0)
    final s = saturation / 100.0;
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;
    m = _multiply(m, [
      sr + s, sg,     sb,     0, 0,
      sr,     sg + s, sb,     0, 0,
      sr,     sg,     sb + s, 0, 0,
      0,      0,      0,      1, 0,
    ]);
    // Hue rotation.
    if (hue != 0) {
      final rad = hue * 3.1415926535 / 180.0;
      final cosV = _cos(rad), sinV = _sin(rad);
      m = _multiply(m, [
        0.213 + cosV * 0.787 - sinV * 0.213, 0.715 - cosV * 0.715 - sinV * 0.715, 0.072 - cosV * 0.072 + sinV * 0.928, 0, 0,
        0.213 - cosV * 0.213 + sinV * 0.143, 0.715 + cosV * 0.285 + sinV * 0.140, 0.072 - cosV * 0.072 - sinV * 0.283, 0, 0,
        0.213 - cosV * 0.213 - sinV * 0.787, 0.715 - cosV * 0.715 + sinV * 0.715, 0.072 + cosV * 0.928 + sinV * 0.072, 0, 0,
        0, 0, 0, 1, 0,
      ]);
    }
    // Grayscale (blend toward luminance).
    if (grayscale > 0) {
      final g = grayscale / 100.0;
      m = _multiply(m, [
        lr * g + (1 - g), lg * g, lb * g, 0, 0,
        lr * g, lg * g + (1 - g), lb * g, 0, 0,
        lr * g, lg * g, lb * g + (1 - g), 0, 0,
        0, 0, 0, 1, 0,
      ]);
    }
    // Sepia.
    if (sepia > 0) {
      final p = sepia / 100.0;
      final inv = 1 - p;
      m = _multiply(m, [
        (0.393 * p) + inv, 0.769 * p, 0.189 * p, 0, 0,
        0.349 * p, (0.686 * p) + inv, 0.168 * p, 0, 0,
        0.272 * p, 0.534 * p, (0.131 * p) + inv, 0, 0,
        0, 0, 0, 1, 0,
      ]);
    }
    return m;
  }

  ColorFilter colorFilter() => ColorFilter.matrix(colorMatrix());

  ImageFilter? blurFilter() =>
      blur > 0 ? ImageFilter.blur(sigmaX: blur, sigmaY: blur) : null;

  // ── 4x5 matrix helpers ──────────────────────────────────────────────────────
  static List<double> _identity() => [
        1, 0, 0, 0, 0,
        0, 1, 0, 0, 0,
        0, 0, 1, 0, 0,
        0, 0, 0, 1, 0,
      ];

  static List<double> _multiply(List<double> a, List<double> b) {
    final out = List<double>.filled(20, 0);
    for (int row = 0; row < 4; row++) {
      for (int col = 0; col < 5; col++) {
        var sum = 0.0;
        for (int k = 0; k < 4; k++) {
          sum += a[row * 5 + k] * b[k * 5 + col];
        }
        if (col == 4) sum += a[row * 5 + 4];
        out[row * 5 + col] = sum;
      }
    }
    return out;
  }

  static double _cos(double x) => math.cos(x);
  static double _sin(double x) => math.sin(x);
}

// ── Presets (Section 8) ───────────────────────────────────────────────────────
class FilterPreset {
  final String name;
  final CameraFilters filters;
  const FilterPreset(this.name, this.filters);
}

const List<FilterPreset> kFilterPresets = [
  FilterPreset('Natural', CameraFilters()),
  FilterPreset('Warm', CameraFilters(brightness: 105, saturation: 115, hue: 10, sepia: 15)),
  FilterPreset('Cool', CameraFilters(brightness: 100, saturation: 110, hue: 340)),
  FilterPreset('Dramatic', CameraFilters(brightness: 95, contrast: 140, saturation: 120)),
  FilterPreset('B&W', CameraFilters(grayscale: 100, contrast: 110)),
  FilterPreset('Church Glow', CameraFilters(brightness: 112, contrast: 105, saturation: 108, sepia: 20)),
  FilterPreset('Reset', CameraFilters()),
];
