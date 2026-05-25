import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class DiscoveredServer {
  final String host;
  final String name;
  final int controlPort;
  final int videoPort;
  final int mjpegPort;
  int lastSeen;
  DiscoveredServer({
    required this.host,
    required this.name,
    required this.controlPort,
    required this.videoPort,
    required this.mjpegPort,
    required this.lastSeen,
  });
}

const int _discoveryPort = 8767;
const int _staleTimeoutMs = 8000;

/// Listens for the desktop's UDP beacons (broadcast every 2s on port 8767) and
/// exposes a live list of servers found on the LAN. Pure Dart — no native code.
///
/// The beacon JSON is:
///   { service:'church-live-stream', host, name, controlPort, videoPort, mjpegPort, t }
class DiscoveryService extends ChangeNotifier {
  RawDatagramSocket? _socket;
  Timer? _sweeper;
  final Map<String, DiscoveredServer> _servers = {};

  List<DiscoveredServer> get servers {
    final list = _servers.values.toList();
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  Future<void> start() async {
    if (_socket != null) return;
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _discoveryPort,
        reuseAddress: true,
        reusePort: false,
      );
      _socket!.broadcastEnabled = true;
      _socket!.listen(_onEvent);
      debugPrint('[Discovery] listening on UDP $_discoveryPort');
    } catch (e) {
      // Another app may hold the port, or the OS may block binding. Discovery is
      // optional — the user can still scan a QR or type the IP.
      debugPrint('[Discovery] bind failed: $e');
    }

    _sweeper = Timer.periodic(const Duration(seconds: 2), (_) {
      final now = DateTime.now().millisecondsSinceEpoch;
      var changed = false;
      _servers.removeWhere((_, s) {
        final stale = now - s.lastSeen > _staleTimeoutMs;
        if (stale) changed = true;
        return stale;
      });
      if (changed) notifyListeners();
    });
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    try {
      final msg = jsonDecode(utf8.decode(dg.data));
      if (msg is! Map) return;
      if (msg['service'] != 'church-live-stream' || msg['host'] == null) return;
      final host = msg['host'].toString();
      final controlPort = (msg['controlPort'] is int) ? msg['controlPort'] as int : 8765;
      final key = '$host:$controlPort';
      _servers[key] = DiscoveredServer(
        host: host,
        name: (msg['name'] ?? 'Desktop').toString(),
        controlPort: controlPort,
        videoPort: (msg['videoPort'] is int) ? msg['videoPort'] as int : 8766,
        mjpegPort: (msg['mjpegPort'] is int) ? msg['mjpegPort'] as int : 18850,
        lastSeen: DateTime.now().millisecondsSinceEpoch,
      );
      notifyListeners();
    } catch (_) {}
  }

  void stop() {
    _sweeper?.cancel();
    _sweeper = null;
    _socket?.close();
    _socket = null;
    _servers.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
