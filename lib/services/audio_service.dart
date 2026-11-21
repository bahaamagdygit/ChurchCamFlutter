import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Phone microphone → desktop. The native side (AudioStreamer.kt) delivers
/// 20 ms PCM chunks (s16le, mono, 48 kHz); this forwards them to [onPcm] and
/// exposes a smoothed level for the on-screen meter.
class AudioService extends ChangeNotifier {
  static const _method = MethodChannel('churchcam/audio');
  static const _events = EventChannel('churchcam/audio/pcm');

  StreamSubscription? _sub;
  bool _running = false;
  double _level = 0; // 0..1, smoothed
  int _lastNotifyMs = 0;

  bool get running => _running;
  double get level => _level;

  void Function(Uint8List pcm)? onPcm;

  /// Start capturing. Returns false if the mic permission is refused or the
  /// device can't open the microphone.
  Future<bool> start() async {
    if (_running) return true;
    final status = await Permission.microphone.request();
    if (!status.isGranted) return false;
    _sub = _events.receiveBroadcastStream().listen((e) {
      if (e is! Map) return;
      final data = e['data'];
      final lvl = (e['level'] as num?)?.toDouble() ?? 0;
      if (data is Uint8List) onPcm?.call(data);
      // Fast attack, slow release — reads like a real meter.
      _level = lvl > _level ? lvl : _level * 0.85 + lvl * 0.15;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastNotifyMs > 80) { _lastNotifyMs = now; notifyListeners(); }
    });
    bool ok = false;
    try { ok = await _method.invokeMethod<bool>('start') ?? false; } catch (_) {}
    if (!ok) {
      await _sub?.cancel();
      _sub = null;
      return false;
    }
    _running = true;
    notifyListeners();
    return true;
  }

  Future<void> stop() async {
    try { await _method.invokeMethod('stop'); } catch (_) {}
    await _sub?.cancel();
    _sub = null;
    _running = false;
    _level = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
