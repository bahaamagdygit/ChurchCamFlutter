import 'dart:typed_data';
import 'dart:ui' show Offset;
import 'package:flutter_test/flutter_test.dart';
import 'package:church_cam_flutter/services/smart_framer.dart';

/// 1280×720 luma frame: textured background + a bright "person" blob at (px,py).
Uint8List frame(int px, int py) {
  const w = 1280, h = 720;
  final y = Uint8List(w * h);
  for (int j = 0; j < h; j++) {
    for (int i = 0; i < w; i++) {
      y[j * w + i] = 60 + ((i ~/ 40 + j ~/ 40) % 2) * 20; // checkerboard
    }
  }
  for (int j = -60; j < 60; j++) {
    for (int i = -30; i < 30; i++) {
      final x = px + i, yy = py + j;
      if (x < 0 || yy < 0 || x >= w || yy >= h) continue;
      y[yy * w + x] = (i.abs() < 12 && j < -30) ? 230 : 180; // head + body
    }
  }
  return y;
}

void main() {
  test('tracker follows a moving subject', () {
    final t = PatchTracker();
    t.lockAt(frame(400, 360), 1280, 720, 1280, 400 / 1280, 340 / 720);
    expect(t.active, isTrue);
    for (int k = 1; k <= 30; k++) {
      t.update(frame(400 + k * 12, 360), 1280, 720, 1280);
    }
    expect(t.lost, isFalse);
    expect((t.x * 1280 - (400 + 30 * 12)).abs(), lessThan(24));
  });

  test('framer zooms in smoothly and keeps the crop inside the frame', () {
    final f = SmartFramer();
    f.lock(const Offset(0.95, 0.05), zoom: ShotSize.close);
    double prevZoom = f.zoom;
    for (int i = 0; i < 90; i++) {
      f.tick(1 / 30);
      expect(f.zoom, greaterThanOrEqualTo(prevZoom - 1e-9)); // monotonic, no overshoot
      prevZoom = f.zoom;
      final c = f.crop;
      expect(c.left, greaterThanOrEqualTo(-1e-9));
      expect(c.top, greaterThanOrEqualTo(-1e-9));
      expect(c.right, lessThanOrEqualTo(1 + 1e-9));
      expect(c.bottom, lessThanOrEqualTo(1 + 1e-9));
    }
    expect(f.zoom, closeTo(ShotSize.close, 0.05));

    f.release();
    for (int i = 0; i < 150; i++) { f.tick(1 / 30); }
    expect(f.isIdentity, isTrue);
  });

  test('dead zone ignores small subject jitter', () {
    final f = SmartFramer();
    f.lock(const Offset(0.5, 0.5), zoom: ShotSize.medium);
    final tx = f.tx, ty = f.ty;
    f.onSubject(const Offset(0.52, 0.51));
    expect(f.tx, tx);
    expect(f.ty, ty);
  });
}
