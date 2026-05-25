import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/connection_service.dart';

/// Persistent latency badge (Section 2): green <50ms, yellow 50-150ms,
/// red >150ms or while reconnecting. Shows the exact latency in ms.
class ConnectionBadge extends StatelessWidget {
  const ConnectionBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ConnectionService>(
      builder: (_, conn, __) {
        final reconnecting = conn.status == ConnectionStatus.reconnecting ||
            conn.status == ConnectionStatus.connecting;
        final ms = conn.latencyMs;
        Color color;
        String label;
        if (reconnecting || conn.status != ConnectionStatus.connected) {
          color = const Color(0xFFEF4444);
          label = reconnecting ? 'Reconnecting…' : 'Offline';
        } else if (ms < 50) {
          color = const Color(0xFF22C55E);
          label = '${ms}ms';
        } else if (ms <= 150) {
          color = const Color(0xFFF59E0B);
          label = '${ms}ms';
        } else {
          color = const Color(0xFFEF4444);
          label = '${ms}ms';
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xCC0A0A14),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
            ],
          ),
        );
      },
    );
  }
}
