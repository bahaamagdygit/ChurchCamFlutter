import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

/// Shot sizes for Smart Zoom (digital crop factor).
class ShotSize {
  static const double wide = 1.5;
  static const double medium = 2.0;
  static const double close = 2.8;
  static const double max = 4.0;
}

/// Lightweight single-target tracker on the camera's luma (Y) plane.
///
/// The person is locked by tapping them. A small, centre-weighted grey patch
/// around that point becomes the template; every update searches a window
/// around the last position for the best zero-mean SAD match (robust to the
/// overall brightness changing as stage lights move). The template slowly
/// adapts while the match is confident, so a person turning or stepping keeps
/// being followed. Everything works on a ~160px-wide copy of the frame, so one
/// update is a few hundred thousand integer ops — cheap enough for 15 Hz on the
/// UI isolate.
///
/// Coordinates are normalized (0..1) in SOURCE (sensor) space.
class PatchTracker {
  static const int _targetGrayWidth = 160;
  static const int _half = 9;            // template is (2*_half+1)² = 19×19
  static const int _searchRadius = 12;   // px in the grey image per update

  Uint8List _gray = Uint8List(0);
  int _gw = 0, _gh = 0;

  Float32List? _tpl;                     // zero-mean template values
  late final Float32List _weights = _buildWeights();
  double _weightSum = 1;

  bool active = false;
  double x = 0.5, y = 0.5;               // source-normalized
  double confidence = 0;                 // 0..1
  int _badStreak = 0;

  /// True after several consecutive poor matches — the subject has left the
  /// frame or been occluded. The framer holds its last position.
  bool get lost => active && _badStreak >= 8;

  Float32List _buildWeights() {
    const n = 2 * _half + 1;
    final w = Float32List(n * n);
    const sigma = _half * 0.65;
    double sum = 0;
    for (int j = 0; j < n; j++) {
      for (int i = 0; i < n; i++) {
        final dx = i - _half, dy = j - _half;
        final v = math.exp(-(dx * dx + dy * dy) / (2 * sigma * sigma));
        w[j * n + i] = v;
        sum += v;
      }
    }
    _weightSum = sum;
    return w;
  }

  void _buildGray(Uint8List yPlane, int width, int height, int rowStride) {
    final step = math.max(1, width ~/ _targetGrayWidth);
    final gw = width ~/ step, gh = height ~/ step;
    if (_gray.length != gw * gh) _gray = Uint8List(gw * gh);
    final len = yPlane.length;
    int i = 0;
    for (int yy = 0; yy < gh; yy++) {
      final row = yy * step * rowStride;
      for (int xx = 0; xx < gw; xx++) {
        final idx = row + xx * step;
        _gray[i++] = idx < len ? yPlane[idx] : 0;
      }
    }
    _gw = gw;
    _gh = gh;
  }

  /// Lock onto the point (nx, ny) of this frame.
  void lockAt(Uint8List yPlane, int width, int height, int rowStride, double nx, double ny) {
    _buildGray(yPlane, width, height, rowStride);
    if (_gw < 4 * _half || _gh < 4 * _half) return;
    final cx = (nx * _gw).round().clamp(_half, _gw - _half - 1);
    final cy = (ny * _gh).round().clamp(_half, _gh - _half - 1);
    _tpl = _extract(cx, cy);
    x = cx / _gw;
    y = cy / _gh;
    active = true;
    confidence = 1;
    _badStreak = 0;
  }

  void release() {
    active = false;
    _tpl = null;
    _badStreak = 0;
    confidence = 0;
  }

  Float32List _extract(int cx, int cy) {
    const n = 2 * _half + 1;
    final out = Float32List(n * n);
    double mean = 0;
    for (int j = 0; j < n; j++) {
      final row = (cy - _half + j) * _gw + (cx - _half);
      for (int i = 0; i < n; i++) {
        final v = _gray[row + i].toDouble();
        out[j * n + i] = v;
        mean += v;
      }
    }
    mean /= n * n;
    for (int k = 0; k < out.length; k++) {
      out[k] -= mean;
    }
    return out;
  }

  /// Weighted zero-mean SAD between the template and the patch at (cx, cy).
  /// Returns the mean absolute difference in grey levels (lower = better).
  double _score(Float32List tpl, int cx, int cy) {
    const n = 2 * _half + 1;
    double mean = 0;
    for (int j = 0; j < n; j++) {
      final row = (cy - _half + j) * _gw + (cx - _half);
      for (int i = 0; i < n; i++) {
        mean += _gray[row + i];
      }
    }
    mean /= n * n;
    double sad = 0;
    for (int j = 0; j < n; j++) {
      final row = (cy - _half + j) * _gw + (cx - _half);
      final base = j * n;
      for (int i = 0; i < n; i++) {
        final d = (_gray[row + i] - mean) - tpl[base + i];
        sad += (d < 0 ? -d : d) * _weights[base + i];
      }
    }
    return sad / _weightSum;
  }

  /// Search for the subject in a new frame. Coarse 2-px grid, then a 1-px
  /// refinement around the best coarse hit.
  void update(Uint8List yPlane, int width, int height, int rowStride) {
    final tpl = _tpl;
    if (!active || tpl == null) return;
    _buildGray(yPlane, width, height, rowStride);
    if (_gw < 4 * _half || _gh < 4 * _half) return;

    final px = (x * _gw).round(), py = (y * _gh).round();
    final minX = _half, maxX = _gw - _half - 1;
    final minY = _half, maxY = _gh - _half - 1;

    double best = double.infinity;
    int bx = px.clamp(minX, maxX), by = py.clamp(minY, maxY);
    for (int dy = -_searchRadius; dy <= _searchRadius; dy += 2) {
      final cy = py + dy;
      if (cy < minY || cy > maxY) continue;
      for (int dx = -_searchRadius; dx <= _searchRadius; dx += 2) {
        final cx = px + dx;
        if (cx < minX || cx > maxX) continue;
        final s = _score(tpl, cx, cy);
        if (s < best) { best = s; bx = cx; by = cy; }
      }
    }
    final cbx = bx, cby = by;
    for (int dy = -1; dy <= 1; dy++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final cx = cbx + dx, cy = cby + dy;
        if (cx < minX || cx > maxX || cy < minY || cy > maxY) continue;
        final s = _score(tpl, cx, cy);
        if (s < best) { best = s; bx = cx; by = cy; }
      }
    }

    // ~grey levels of mean difference. Sensor noise on a good match sits well
    // under 10; a different object is typically 20+.
    confidence = (1 - best / 28).clamp(0.0, 1.0);
    if (best < 18) {
      _badStreak = 0;
      x = bx / _gw;
      y = by / _gh;
      // Adapt slowly while confident, so pose changes are absorbed without the
      // template drifting onto the background.
      if (best < 11) {
        final fresh = _extract(bx, by);
        for (int k = 0; k < tpl.length; k++) {
          tpl[k] = tpl[k] * 0.9 + fresh[k] * 0.1;
        }
      }
    } else {
      _badStreak++;
    }
  }
}

/// Cinematic framing: turns a subject position into a smoothly moving crop.
///
/// Works in OUTPUT space (what the audience sees, after mirror/rotation).
/// Behaves like a good camera operator rather than a lock-on reticle:
///   • critically-damped springs — moves ease in and settle without overshoot;
///   • a dead zone — small movements of the subject don't move the shot;
///   • headroom — the subject's tapped point (usually the face) sits on the
///     upper third instead of dead centre;
///   • a speed cap on pans, so a sudden tracker jump never whips the frame;
///   • zoom animated in log space, so 1×→2× feels as even as 2×→4×.
class SmartFramer {
  // Current (smoothed) framing.
  double cx = 0.5, cy = 0.5, zoom = 1.0;
  double _vx = 0, _vy = 0, _vlz = 0;

  // Target framing.
  double tx = 0.5, ty = 0.5, tz = 1.0;

  bool locked = false;
  bool follow = true;
  bool lost = false;
  double shotZoom = ShotSize.medium;

  /// Digital zoom used when the phone has no hardware zoom (centre crop).
  double baseZoom = 1.0;

  /// Manual framing centre when not following anyone (one-finger pan, saved
  /// shots). Smart Zoom release glides back here.
  double mx = 0.5, my = 0.5;

  /// Digital stabilisation: a minimum crop that leaves margin to absorb shake,
  /// and the current correction offset (output space, added to the centre).
  double stabMinZoom = 1.0;
  double stabX = 0, stabY = 0;

  /// Effective zoom actually applied (manual / smart zoom, never below the
  /// stabiliser's margin).
  double get _floorZoom => math.max(1.0, stabMinZoom);

  /// Last known subject position (output space), for the on-phone marker.
  Offset? subject;

  static const double _posOmega = 3.2;   // rad/s — ~1.2 s settle
  static const double _zoomOmega = 2.6;
  static const double _maxPanSpeed = 0.55; // frame-widths per second

  bool get isIdentity => zoom < 1.002 && tz < 1.002 && stabX == 0 && stabY == 0;

  void lock(Offset p, {double? zoom}) {
    locked = true;
    lost = false;
    if (zoom != null) shotZoom = zoom.clamp(1.0, ShotSize.max);
    tz = shotZoom;
    subject = p;
    _aimAt(p, force: true);
  }

  void release() {
    locked = false;
    lost = false;
    subject = null;
    tz = math.max(baseZoom, _floorZoom);
    tx = mx;
    ty = my;
    _clampTarget();
  }

  /// Glide to an exact framing (saved shot recall). Not a lock: nobody is
  /// followed, the frame just moves there like a motorised head would.
  void goTo(double centreX, double centreY, double cropZoom) {
    locked = false;
    lost = false;
    subject = null;
    baseZoom = cropZoom.clamp(1.0, ShotSize.max);
    mx = centreX;
    my = centreY;
    tz = math.max(baseZoom, _floorZoom);
    tx = mx;
    ty = my;
    _clampTarget();
    mx = tx;
    my = ty;
  }

  /// One-finger pan of a zoomed frame. [dx]/[dy] are in output-frame units
  /// (a full-width drag = 1.0). Moves immediately so it tracks the finger.
  void panBy(double dx, double dy) {
    if (locked) return;
    final h = 0.5 / math.max(tz, 1.0);
    mx = (mx - dx).clamp(h, 1 - h);
    my = (my - dy).clamp(h, 1 - h);
    tx = mx;
    ty = my;
    cx = mx;
    cy = my;
    _vx = _vy = 0;
  }

  void setShot(double z) {
    shotZoom = z.clamp(1.0, ShotSize.max);
    if (locked) {
      tz = shotZoom;
      if (subject != null) _aimAt(subject!, force: true);
    }
  }

  void setBaseZoom(double z) {
    baseZoom = z.clamp(1.0, ShotSize.max);
    if (!locked) {
      // Keep the operator's framing centre while zooming (only re-clamped so
      // the crop stays inside the picture).
      tz = math.max(baseZoom, _floorZoom);
      tx = mx;
      ty = my;
      _clampTarget();
      if (baseZoom <= 1.0005) { mx = 0.5; my = 0.5; tx = 0.5; ty = 0.5; }
    }
  }

  /// Turn the stabiliser's crop margin on/off.
  void setStabilizerMargin(bool on) {
    stabMinZoom = on ? 1.12 : 1.0;
    if (!on) { stabX = 0; stabY = 0; }
    if (!locked) tz = math.max(baseZoom, _floorZoom);
  }

  /// New subject position from the tracker.
  void onSubject(Offset p) {
    subject = p;
    lost = false;
    if (locked && follow) _aimAt(p);
  }

  void _aimAt(Offset p, {bool force = false}) {
    final w = 1 / tz;
    // Tapped point on the upper third of the shot → centre sits below it.
    final desiredX = p.dx;
    final desiredY = p.dy + 0.14 * w;
    if (force) {
      tx = desiredX;
      ty = desiredY;
    } else {
      final dzX = 0.12 * w, dzY = 0.09 * w;
      final ex = desiredX - tx, ey = desiredY - ty;
      if (ex.abs() > dzX) tx = desiredX - dzX * ex.sign;
      if (ey.abs() > dzY) ty = desiredY - dzY * ey.sign;
    }
    _clampTarget();
  }

  void _clampTarget() {
    final h = 0.5 / tz;
    tx = tx.clamp(h, 1 - h);
    ty = ty.clamp(h, 1 - h);
  }

  /// Advance the springs by [dt] seconds.
  void tick(double dt) {
    if (dt <= 0) return;
    dt = math.min(dt, 0.1);

    // Zoom in log space.
    final lz = math.log(zoom), ltz = math.log(tz);
    final zr = _spring(lz, _vlz, ltz, _zoomOmega, dt);
    zoom = math.exp(zr.$1).clamp(1.0, ShotSize.max);
    _vlz = zr.$2;

    final xr = _spring(cx, _vx, tx, _posOmega, dt);
    final yr = _spring(cy, _vy, ty, _posOmega, dt);
    _vx = xr.$2.clamp(-_maxPanSpeed, _maxPanSpeed);
    _vy = yr.$2.clamp(-_maxPanSpeed, _maxPanSpeed);
    cx = xr.$1;
    cy = yr.$1;

    // The crop must always stay inside the frame at the CURRENT zoom.
    final h = 0.5 / zoom;
    cx = cx.clamp(h, 1 - h);
    cy = cy.clamp(h, 1 - h);

    // Snap to exact identity when fully zoomed out, so the encoder takes the
    // untouched full-frame path.
    if (!locked && tz <= 1.0005 && (zoom - 1).abs() < 0.002 && stabMinZoom <= 1.0) {
      zoom = 1;
      cx = 0.5;
      cy = 0.5;
      _vx = _vy = _vlz = 0;
    }
  }

  /// Implicit critically-damped spring step (stable for any dt).
  (double, double) _spring(double x, double v, double target, double omega, double dt) {
    final f = 1 + 2 * dt * omega;
    final oo = omega * omega;
    final hoo = dt * oo;
    final hhoo = dt * hoo;
    final detInv = 1 / (f + hhoo);
    final nx = (f * x + dt * v + hhoo * target) * detInv;
    final nv = (v + hoo * (target - x)) * detInv;
    return (nx, nv);
  }

  /// Current crop in output space, normalized (stabiliser correction applied,
  /// kept inside the frame).
  Rect get crop {
    final w = 1 / zoom;
    final h = w / 2;
    final x = (cx + stabX).clamp(h, 1 - h);
    final y = (cy + stabY).clamp(h, 1 - h);
    return Rect.fromLTWH(x - h, y - h, w, w);
  }

  /// Map a point given relative to the CURRENT program output (what the
  /// desktop shows) back to the full output frame.
  Offset programToFull(Offset p) {
    final c = crop;
    return Offset(c.left + p.dx * c.width, c.top + p.dy * c.height);
  }
}
