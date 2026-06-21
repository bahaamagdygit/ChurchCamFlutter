import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';
import '../services/camera_service.dart';
import '../services/device_status_service.dart';

/// Compact live metrics HUD for professional monitoring: latency, FPS, bitrate,
/// dropped frames, codec/quality, link grade, battery and WiFi signal. Rebuilds
/// on connection + camera + device-status changes (all ChangeNotifiers).
class MetricsOverlay extends StatelessWidget {
  const MetricsOverlay({super.key, required this.camera, required this.status});

  final CameraService camera;
  final DeviceStatusService status;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([camera, status]),
      builder: (_, __) => Consumer<ConnectionService>(
        builder: (_, conn, ___) {
          final q = conn.quality;
          final color = _qualityColor(q);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xCC0A0A14),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withValues(alpha: 0.6), width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('LATENCY', '${conn.latencyMs} ms', _latencyColor(conn.latencyMs)),
                _row('FPS', '${camera.measuredFps}/${camera.targetFps}', Colors.white),
                _row('BITRATE', _fmtKbps(conn.sendBitrateKbps), Colors.white),
                _row('ENCODE', '${camera.avgEncodeMs.toStringAsFixed(0)} ms', Colors.white),
                _row('DROPPED', '${conn.framesDropped}',
                    conn.framesDropped > 0 ? const Color(0xFFF59E0B) : Colors.white),
                _row('QUALITY', camera.qualityLabel, Colors.white),
                _row('LINK', _qualityName(q), color),
                _row('WIFI', _wifiText(status), _wifiColor(status.wifiBars)),
                _row('BATTERY', _batteryText(status), _batteryColor(status)),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _wifiText(DeviceStatusService s) =>
      s.wifiRssi <= -127 ? '—' : '${'▮' * s.wifiBars}${'▯' * (4 - s.wifiBars)}  ${s.wifiRssi}dBm';

  static Color _wifiColor(int bars) {
    if (bars >= 4) return const Color(0xFF22C55E);
    if (bars >= 3) return const Color(0xFF84CC16);
    if (bars >= 2) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  static String _batteryText(DeviceStatusService s) =>
      s.batteryPercent < 0 ? '—' : '${s.batteryPercent}%${s.charging ? ' ⚡' : ''}';

  static Color _batteryColor(DeviceStatusService s) {
    if (s.charging) return const Color(0xFF22C55E);
    if (s.batteryPercent < 0) return Colors.white;
    if (s.batteryPercent <= 15) return const Color(0xFFEF4444);
    if (s.batteryPercent <= 30) return const Color(0xFFF59E0B);
    return Colors.white;
  }

  Widget _row(String k, String v, Color vColor) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 62,
              child: Text(k,
                  style: const TextStyle(
                      color: Color(0xFF8A8AA8), fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
            ),
            Text(v, style: TextStyle(color: vColor, fontSize: 11, fontWeight: FontWeight.w700)),
          ],
        ),
      );

  static String _fmtKbps(int kbps) =>
      kbps >= 1000 ? '${(kbps / 1000).toStringAsFixed(1)} Mbps' : '$kbps kbps';

  static Color _latencyColor(int ms) {
    if (ms < 150) return const Color(0xFF22C55E);
    if (ms <= 250) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }

  static Color _qualityColor(LinkQuality q) {
    switch (q) {
      case LinkQuality.excellent:
        return const Color(0xFF22C55E);
      case LinkQuality.good:
        return const Color(0xFF84CC16);
      case LinkQuality.fair:
        return const Color(0xFFF59E0B);
      case LinkQuality.poor:
        return const Color(0xFFEF4444);
      case LinkQuality.disconnected:
        return const Color(0xFF6B7280);
    }
  }

  static String _qualityName(LinkQuality q) {
    switch (q) {
      case LinkQuality.excellent:
        return 'Excellent';
      case LinkQuality.good:
        return 'Good';
      case LinkQuality.fair:
        return 'Fair';
      case LinkQuality.poor:
        return 'Poor';
      case LinkQuality.disconnected:
        return 'Offline';
    }
  }
}
