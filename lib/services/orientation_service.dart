import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Derives the real device orientation (0/90/180/270) from the accelerometer,
/// independent of any UI orientation lock. Emits only when the angle changes.
class OrientationService extends ChangeNotifier {
  StreamSubscription<AccelerometerEvent>? _sub;
  int _angle = 0;
  int get angle => _angle;

  void start() {
    _sub ??= accelerometerEventStream(
      samplingPeriod: const Duration(milliseconds: 200),
    ).listen(_onEvent, onError: (_) {});
  }

  void _onEvent(AccelerometerEvent e) {
    // Gravity dominates; pick the axis with the largest magnitude.
    final ax = e.x, ay = e.y;
    int newAngle = _angle;
    if (ay.abs() > ax.abs()) {
      newAngle = ay >= 0 ? 0 : 180; // portrait / upside-down
    } else {
      newAngle = ax >= 0 ? 90 : 270; // landscape-right / landscape-left
    }
    if (newAngle != _angle) {
      _angle = newAngle;
      notifyListeners();
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
