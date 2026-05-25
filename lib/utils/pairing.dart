import 'dart:convert';

/// A parsed pairing target: where to reach the desktop.
class PairingPayload {
  final String host;
  final int controlPort;
  final int videoPort;
  const PairingPayload({
    required this.host,
    this.controlPort = 8765,
    this.videoPort = 8766,
  });
}

/// Parse whatever the desktop QR encodes (or what the user types) into a target.
/// Mirrors ChurchCamApp's parser: JSON payload, church://, ws://, http://, or
/// a plain `ip` / `ip:port`.
PairingPayload? parsePairing(String raw) {
  var t = raw.trim().replaceAll(RegExp(r'/+$'), '');
  if (t.isEmpty) return null;

  // 1) JSON payload from the desktop QR: { host, controlPort, videoPort }
  if (t.startsWith('{')) {
    try {
      final obj = jsonDecode(t);
      if (obj is Map && obj['host'] is String) {
        return PairingPayload(
          host: obj['host'] as String,
          controlPort: obj['controlPort'] is int ? obj['controlPort'] as int : 8765,
          videoPort: obj['videoPort'] is int ? obj['videoPort'] as int : 8766,
        );
      }
    } catch (_) {}
  }

  // 2) church://host:port
  final church = RegExp(r'^church://([^:/]+)(?::(\d+))?').firstMatch(t);
  if (t.startsWith('church://') && church != null) {
    return PairingPayload(
      host: church.group(1)!,
      controlPort: church.group(2) != null ? int.parse(church.group(2)!) : 8765,
    );
  }

  // 3) ws:// or wss://
  if (t.startsWith('ws://') || t.startsWith('wss://')) {
    final m = RegExp(r'^wss?://([^:/]+)(?::(\d+))?').firstMatch(t);
    if (m != null) {
      return PairingPayload(
        host: m.group(1)!,
        controlPort: m.group(2) != null ? int.parse(m.group(2)!) : 8765,
      );
    }
  }

  // 4) http:// or https:// → treat host the same way
  if (t.startsWith('http://') || t.startsWith('https://')) {
    final stripped = t.replaceFirst(RegExp(r'^https?://'), '');
    final m = RegExp(r'^([^:/]+)(?::(\d+))?').firstMatch(stripped);
    if (m != null) {
      return PairingPayload(
        host: m.group(1)!,
        controlPort: m.group(2) != null ? int.parse(m.group(2)!) : 8765,
      );
    }
  }

  // 5) plain ip:port
  final ipPort = RegExp(r'^([^:]+):(\d+)$').firstMatch(t);
  if (ipPort != null) {
    return PairingPayload(host: ipPort.group(1)!, controlPort: int.parse(ipPort.group(2)!));
  }

  // 6) plain ip / hostname
  if (RegExp(r'^[a-zA-Z0-9.\-]+$').hasMatch(t)) {
    return PairingPayload(host: t);
  }

  return null;
}
