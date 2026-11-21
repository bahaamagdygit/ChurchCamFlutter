import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:church_cam_flutter/services/frame_analysis.dart';
import 'package:church_cam_flutter/services/smart_framer.dart';

/// Textured 960×540 luma frame shifted by (sx, sy) pixels.
Uint8List frame(int sx, int sy) {
  const w = 960, h = 540;
  final y = Uint8List(w * h);
  for (int j = 0; j < h; j++) {
    for (int i = 0; i < w; i++) {
      final x = i - sx, yy = j - sy;
      y[j * w + i] = (((x ~/ 37) * 53 + (yy ~/ 29) * 97) % 200 + 20);
    }
  }
  return y;
}

void main() {
  test('stabiliser cancels shake: crop follows the content', () {
    final s = Stabilizer();
    s.update(frame(0, 0), 960, 540, 960);
    // Sudden shake: content jumps +20 px right (camera moved left).
    s.update(frame(20, 0), 960, 540, 960);
    // Content moved right → crop must move right (positive) to hold it still.
    expect(s.corrX, greaterThan(0.005));
    expect(s.corrY.abs(), lessThan(0.005));
  });

  test('stabiliser lets a slow deliberate pan through', () {
    final s = Stabilizer();
    for (int k = 0; k <= 60; k++) {
      s.update(frame(k * 2, 0), 960, 540, 960); // steady 2 px/frame pan
    }
    // Correction stays bounded (EMA lag) rather than growing with the pan.
    expect(s.corrX.abs(), lessThanOrEqualTo(0.05));
  });

  test('pan moves a zoomed frame and stays inside the picture', () {
    final f = SmartFramer();
    f.setBaseZoom(2.0);
    for (int i = 0; i < 90; i++) { f.tick(1 / 30); }
    f.panBy(-0.4, 0); // drag left → frame moves right
    final c = f.crop;
    expect(c.right, lessThanOrEqualTo(1.0 + 1e-9));
    expect(f.mx, greaterThan(0.5));
  });

  test('saved shot recall glides to the exact framing', () {
    final f = SmartFramer();
    f.goTo(0.3, 0.6, 2.5);
    for (int i = 0; i < 120; i++) { f.tick(1 / 30); }
    expect(f.zoom, closeTo(2.5, 0.02));
    expect(f.cx, closeTo(0.3, 0.01));
    expect(f.cy, closeTo(0.6, 0.01));
  });
}
