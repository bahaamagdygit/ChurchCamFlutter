import 'dart:math' as math;
import 'dart:typed_data';

/// Downsamples the camera's luma (Y) plane into a small grey image. Shared by
/// the stabiliser and the exposure/focus aids so the work is done once.
class LumaThumb {
  Uint8List data = Uint8List(0);
  int w = 0, h = 0;

  void build(Uint8List y, int width, int height, int rowStride, int targetW) {
    final step = math.max(1, width ~/ targetW);
    final tw = width ~/ step, th = height ~/ step;
    if (data.length != tw * th) data = Uint8List(tw * th);
    final len = y.length;
    int i = 0;
    for (int yy = 0; yy < th; yy++) {
      final row = yy * step * rowStride;
      for (int xx = 0; xx < tw; xx++) {
        final idx = row + xx * step;
        data[i++] = idx < len ? y[idx] : 0;
      }
    }
    w = tw;
    h = th;
  }
}

/// Digital image stabilisation (EIS).
///
/// Each frame is compared with the previous one at low resolution to measure
/// the global shift caused by hand shake. The camera's intended path is that
/// motion low-pass filtered; the difference (the jitter) is cancelled by
/// moving the crop the opposite way. Deliberate pans pass through, because the
/// smoothed path follows them — only the high-frequency wobble is removed.
///
/// Offsets are in SOURCE-normalised units (fraction of frame width/height).
class Stabilizer {
  final LumaThumb _prev = LumaThumb();
  bool _hasPrev = false;
  double _rawX = 0, _rawY = 0;      // accumulated camera path
  double _smoothX = 0, _smoothY = 0; // intended (smoothed) path
  double corrX = 0, corrY = 0;      // correction to apply

  static const int _thumbW = 96;
  static const int _radius = 6;     // px at thumb scale per frame

  void reset() {
    _hasPrev = false;
    _rawX = _rawY = _smoothX = _smoothY = corrX = corrY = 0;
  }

  void update(Uint8List y, int width, int height, int rowStride, {double maxCorr = 0.05}) {
    final cur = LumaThumb()..build(y, width, height, rowStride, _thumbW);
    if (!_hasPrev || cur.w != _prev.w || cur.h != _prev.h) {
      _copy(cur);
      _hasPrev = true;
      return;
    }
    // Block match the central 70% (edges move in/out of frame).
    final mx = (cur.w * 0.15).round(), my = (cur.h * 0.15).round();
    double best = double.infinity;
    int bdx = 0, bdy = 0;
    for (int dy = -_radius; dy <= _radius; dy++) {
      for (int dx = -_radius; dx <= _radius; dx++) {
        int sad = 0;
        for (int yy = my; yy < cur.h - my; yy += 2) {
          final py = yy + dy;
          final rowC = yy * cur.w, rowP = py * cur.w;
          for (int xx = mx; xx < cur.w - mx; xx += 2) {
            final d = cur.data[rowC + xx] - _prev.data[rowP + xx + dx];
            sad += d < 0 ? -d : d;
          }
        }
        if (sad < best) { best = sad.toDouble(); bdx = dx; bdy = dy; }
      }
    }
    _copy(cur);
    // cur[x] ≈ prev[x+dx] → content moved by −dx → the camera moved by +dx.
    _rawX += bdx / cur.w;
    _rawY += bdy / cur.h;
    // Intended path: slow EMA. Lower alpha = steadier but laggier.
    _smoothX += (_rawX - _smoothX) * 0.08;
    _smoothY += (_rawY - _smoothY) * 0.08;
    // Shake = raw − smooth (camera ahead of where it meant to be). The scene
    // moved the opposite way in the frame, so the crop follows the scene:
    // offset = −shake. That holds the picture still.
    corrX = (_smoothX - _rawX).clamp(-maxCorr, maxCorr);
    corrY = (_smoothY - _rawY).clamp(-maxCorr, maxCorr);
  }

  void _copy(LumaThumb t) {
    if (_prev.data.length != t.data.length) _prev.data = Uint8List(t.data.length);
    _prev.data.setAll(0, t.data);
    _prev.w = t.w;
    _prev.h = t.h;
  }
}

/// Builds an RGBA overlay (in SOURCE orientation) marking:
///   • zebra  — over-exposed areas (Y ≥ 235) with diagonal stripes;
///   • peaking — in-focus edges (strong local contrast) in bright green.
/// The UI maps it onto the preview with the camera's rotation/mirror.
class AidsAnalyzer {
  final LumaThumb _t = LumaThumb();

  /// Returns (rgba, w, h) or null when nothing is enabled.
  (Uint8List, int, int)? build(Uint8List y, int width, int height, int rowStride, {required bool zebra, required bool peaking}) {
    if (!zebra && !peaking) return null;
    _t.build(y, width, height, rowStride, 320);
    final w = _t.w, h = _t.h, d = _t.data;
    final out = Uint8List(w * h * 4);
    for (int yy = 1; yy < h - 1; yy++) {
      for (int xx = 1; xx < w - 1; xx++) {
        final i = yy * w + xx;
        final o = i * 4;
        if (zebra && d[i] >= 235 && ((xx + yy) ~/ 3) % 2 == 0) {
          out[o] = 255; out[o + 1] = 60; out[o + 2] = 60; out[o + 3] = 200;
          continue;
        }
        if (peaking) {
          final gx = (d[i + 1] - d[i - 1]).abs();
          final gy = (d[i + w] - d[i - w]).abs();
          if (gx + gy > 90) {
            out[o] = 40; out[o + 1] = 255; out[o + 2] = 120; out[o + 3] = 210;
          }
        }
      }
    }
    return (out, w, h);
  }
}
