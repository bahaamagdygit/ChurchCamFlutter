import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:battery_plus/battery_plus.dart';

/// Polls battery level and WiFi signal strength for the metrics HUD and the
/// desktop device list. Lightweight 5s poll — these change slowly.
class DeviceStatusService extends ChangeNotifier {
  static const MethodChannel _device = MethodChannel('churchcam/device');
  final Battery _battery = Battery();

  int _batteryPercent = -1; // -1 = unknown
  bool _charging = false;
  int _wifiBars = 0; // 0..4
  int _wifiRssi = -127; // dBm
  double _tempC = -1; // battery temperature, -1 = unknown
  int _thermal = -1; // Android thermal status 0..6, -1 = unknown

  int get batteryPercent => _batteryPercent;
  bool get charging => _charging;
  int get wifiBars => _wifiBars;
  int get wifiRssi => _wifiRssi;
  double get tempC => _tempC;
  int get thermal => _thermal;

  Timer? _timer;

  void start() {
    _poll();
    _timer ??= Timer.periodic(const Duration(seconds: 5), (_) => _poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      _batteryPercent = level;
      _charging = state == BatteryState.charging || state == BatteryState.full;
    } catch (_) {}
    try {
      final res = await _device.invokeMethod<Map>('wifiSignal');
      if (res != null) {
        _wifiRssi = (res['rssi'] as num?)?.toInt() ?? -127;
        _wifiBars = (res['bars'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}
    try {
      final res = await _device.invokeMethod<Map>('thermal');
      if (res != null) {
        _tempC = (res['tempC'] as num?)?.toDouble() ?? -1;
        _thermal = (res['status'] as num?)?.toInt() ?? -1;
      }
    } catch (_) {}
    notifyListeners();
  }

  /// Snapshot for the desktop handshake / periodic status update.
  Map<String, dynamic> toJson() => {
        'batteryPercent': _batteryPercent,
        'charging': _charging,
        'wifiBars': _wifiBars,
        'wifiRssi': _wifiRssi,
        'tempC': _tempC,
        'thermal': _thermal,
      };

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
