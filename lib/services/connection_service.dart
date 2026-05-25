import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';

enum ConnectionStatus { idle, connecting, connected, error, reconnecting }
enum LinkQuality { excellent, good, fair, poor, disconnected }

LinkQuality qualityFor(int latencyMs) {
  if (latencyMs < 50) return LinkQuality.excellent;
  if (latencyMs < 100) return LinkQuality.good;
  if (latencyMs < 200) return LinkQuality.fair;
  if (latencyMs < 500) return LinkQuality.poor;
  return LinkQuality.disconnected;
}

/// A command pushed from the desktop operator to this phone.
/// `action` is one of: set_zoom / zoom, flip, torch, ... `value` is action-specific.
class RemoteCommand {
  final String action;
  final dynamic value;
  const RemoteCommand(this.action, this.value);
}

void _log(String message) {
  if (kDebugMode) print('[ConnectionService] $message');
}

/// Talks the desktop "mobile-bridge" protocol:
///   • Control: WebSocket on [controlPort] — JSON, bidirectional.
///       phone → { type:'hello', name, capabilities, orientationAngle }
///       desk  → { type:'welcome', deviceId, videoPort }
///       heartbeat both ways via ping/pong.
///       desk  → { type:'command', action, value }   (zoom / flip / torch …)
///       desk  → { type:'reading_update', text, langs }
///   • Video: raw TCP on [videoPort] — first a 32-byte ASCII deviceId header,
///     then length-prefixed (4-byte big-endian) JPEG frames, phone → desktop.
class ConnectionService extends ChangeNotifier {
  static const int CONTROL_PORT = 8765;
  static const int VIDEO_PORT = 8766;
  static const int DISCOVERY_PORT = 8767;

  String _host = '';
  int _controlPort = CONTROL_PORT;
  int _videoPort = VIDEO_PORT;
  String _deviceId = '';
  String _deviceName = 'Mobile Camera (Flutter)';

  WebSocketChannel? _ws;
  Socket? _videoSocket;
  bool _videoHeaderSent = false;

  ConnectionStatus _status = ConnectionStatus.idle;
  int _latencyMs = 0;
  int _framesSent = 0;
  int _framesDropped = 0;
  LinkQuality _quality = LinkQuality.disconnected;

  Timer? _reconnectTimer;
  Timer? _pingTimer;
  int _reconnectAttempts = 0;
  static const int MAX_RECONNECT_ATTEMPTS = 8;
  static const int PING_INTERVAL_MS = 1000;

  // Capabilities advertised to the desktop during handshake.
  Map<String, dynamic> _capabilities = {};
  // Current phone orientation angle (0/90/180/270) sent on hello + on change.
  int _orientationAngle = 0;

  // Reading text overlay pushed from the desktop.
  String _readingText = '';
  List<String> _readingLangs = const [];

  // Listeners interested in remote commands (CameraScreen subscribes here).
  final List<void Function(RemoteCommand)> _commandListeners = [];

  // ── Getters ────────────────────────────────────────────────────────────────
  ConnectionStatus get status => _status;
  int get latencyMs => _latencyMs;
  int get framesSent => _framesSent;
  int get framesDropped => _framesDropped;
  String get deviceId => _deviceId;
  LinkQuality get quality => _quality;
  String get readingText => _readingText;
  List<String> get readingLangs => _readingLangs;
  bool get isVideoReady => _videoSocket != null && _videoHeaderSent;

  void addCommandListener(void Function(RemoteCommand) cb) {
    if (!_commandListeners.contains(cb)) _commandListeners.add(cb);
  }

  void removeCommandListener(void Function(RemoteCommand) cb) {
    _commandListeners.remove(cb);
  }

  void _emitCommand(RemoteCommand cmd) {
    for (final cb in List.of(_commandListeners)) {
      try { cb(cmd); } catch (e) { _log('command listener error: $e'); }
    }
  }

  /// Set before connecting so the desktop shows a friendly name + the right
  /// zoom slider range.
  void configure({String? deviceName, Map<String, dynamic>? capabilities}) {
    if (deviceName != null && deviceName.trim().isNotEmpty) {
      _deviceName = deviceName.trim();
    }
    if (capabilities != null) _capabilities = capabilities;
  }

  Future<bool> connect(String host, int controlPort, int videoPort) async {
    try {
      _host = host;
      _controlPort = controlPort;
      _videoPort = videoPort;

      setStatus(ConnectionStatus.connecting);
      _log('Connecting to $host (control=$controlPort, video=$videoPort)');

      final wsUrl = 'ws://$host:$controlPort';
      try {
        final receivedDeviceId = await _connectWebSocket(wsUrl);
        _deviceId = receivedDeviceId;
        _log('Handshake complete ✓ deviceId=$receivedDeviceId');

        await _connectVideoStream(host, _videoPort, receivedDeviceId);

        setStatus(ConnectionStatus.connected);
        _reconnectAttempts = 0;
        _log('Connection complete ✓');
        return true;
      } catch (e) {
        _log('Connection failed: $e');
        setStatus(ConnectionStatus.error);
        return false;
      }
    } catch (e) {
      _log('Unexpected error during connect: $e');
      setStatus(ConnectionStatus.error);
      return false;
    }
  }

  Future<String> _connectWebSocket(String wsUrl) async {
    final completer = Completer<String>();
    var resolved = false;

    final timeout = Timer(const Duration(seconds: 10), () {
      if (!resolved) {
        resolved = true;
        if (!completer.isCompleted) {
          completer.completeError(Exception('WebSocket connection timeout'));
        }
      }
    });

    try {
      _ws = WebSocketChannel.connect(Uri.parse(wsUrl));

      _ws!.stream.listen(
        (data) => _onControlMessage(data, () {
          if (!resolved) {
            resolved = true;
            timeout.cancel();
            completer.complete(_deviceId);
          }
        }),
        onError: (error) {
          _log('WebSocket error: $error');
          if (!resolved) {
            resolved = true;
            timeout.cancel();
            completer.completeError(error);
          } else {
            _scheduleReconnect();
          }
        },
        onDone: () {
          _log('WebSocket closed');
          if (!resolved) {
            resolved = true;
            timeout.cancel();
            completer.completeError(Exception('WebSocket closed'));
          } else {
            _scheduleReconnect();
          }
        },
        cancelOnError: true,
      );

      // Send the hello handshake immediately. The desktop replies with welcome.
      _send({
        'type': 'hello',
        'name': _deviceName,
        'capabilities': _capabilities,
        'orientationAngle': _orientationAngle,
      });

      _startPing();
      return completer.future;
    } catch (e) {
      _log('WebSocket connection error: $e');
      if (!resolved) {
        resolved = true;
        timeout.cancel();
        completer.completeError(e);
      }
      rethrow;
    }
  }

  void _onControlMessage(dynamic data, void Function() onWelcome) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data as String) as Map<String, dynamic>;
    } catch (e) {
      _log('Bad control message: $e');
      return;
    }

    switch (msg['type']) {
      case 'welcome':
        _deviceId = (msg['deviceId'] ?? '').toString();
        if (msg['videoPort'] is int) _videoPort = msg['videoPort'] as int;
        _log('Welcome: deviceId=$_deviceId videoPort=$_videoPort');
        onWelcome();
        break;

      case 'ping':
        // Desktop heartbeat — echo a pong with the same timestamp.
        _send({'type': 'pong', 't': msg['t']});
        break;

      case 'pong':
        if (msg['t'] is int) {
          _latencyMs = DateTime.now().millisecondsSinceEpoch - (msg['t'] as int);
          _quality = qualityFor(_latencyMs);
          notifyListeners();
        }
        break;

      case 'command':
        final action = (msg['action'] ?? '').toString();
        if (action.isNotEmpty) {
          _log('Command from desktop: $action = ${msg['value']}');
          _emitCommand(RemoteCommand(action, msg['value']));
        }
        break;

      case 'reading_update':
        _readingText = (msg['text'] ?? '').toString();
        final langs = msg['langs'];
        _readingLangs = langs is List
            ? langs.map((e) => e.toString()).toList()
            : const [];
        notifyListeners();
        break;

      case 'filter_state':
      case 'desktop_state':
        // Forwarded to listeners for optional handling.
        _emitCommand(RemoteCommand(msg['type'].toString(), msg['value']));
        break;
    }
  }

  Future<void> _connectVideoStream(String host, int port, String deviceId) async {
    _videoHeaderSent = false;
    try {
      _log('Connecting video stream: $host:$port');
      _videoSocket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 5));
      _videoSocket!.setOption(SocketOption.tcpNoDelay, true);

      // Send the 32-byte ASCII deviceId header (zero-padded).
      final idBytes = utf8.encode(deviceId);
      final header = Uint8List(32);
      for (int i = 0; i < idBytes.length && i < 32; i++) {
        header[i] = idBytes[i];
      }
      _videoSocket!.add(header);
      _videoHeaderSent = true;
      _log('Video stream connected ✓ (header sent)');

      _videoSocket!.listen(
        (_) {},
        onError: (error) {
          _log('Video socket error: $error');
          _videoSocket = null;
          _videoHeaderSent = false;
          _reconnectVideoStream();
        },
        onDone: () {
          _log('Video socket closed');
          _videoSocket = null;
          _videoHeaderSent = false;
          _reconnectVideoStream();
        },
      );
    } catch (e) {
      _videoSocket = null;
      _videoHeaderSent = false;
      _log('Video connection failed: $e');
      rethrow;
    }
  }

  /// Send one JPEG video frame: 4-byte big-endian length prefix + JPEG bytes.
  /// Frames are dropped (counted) when the channel isn't ready.
  void sendFrame(Uint8List jpeg) {
    final sock = _videoSocket;
    if (sock == null || !_videoHeaderSent) {
      _framesDropped++;
      return;
    }
    try {
      final len = jpeg.length;
      final prefix = Uint8List(4)
        ..[0] = (len >> 24) & 0xFF
        ..[1] = (len >> 16) & 0xFF
        ..[2] = (len >> 8) & 0xFF
        ..[3] = len & 0xFF;
      sock.add(prefix);
      sock.add(jpeg);
      _framesSent++;
      // Notify sparingly so the UI counter updates without flooding.
      if (_framesSent % 15 == 0) notifyListeners();
    } catch (e) {
      _framesDropped++;
      _log('sendFrame failed: $e');
    }
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(
      const Duration(milliseconds: PING_INTERVAL_MS),
      (timer) {
        if (_ws == null) {
          timer.cancel();
          return;
        }
        _send({'type': 'ping', 't': DateTime.now().millisecondsSinceEpoch});
      },
    );
  }

  void _send(Map<String, dynamic> obj) {
    try {
      _ws?.sink.add(jsonEncode(obj));
    } catch (e) {
      _log('send failed: $e');
    }
  }

  // ── Outgoing control messages ───────────────────────────────────────────────
  void sendCapabilities(Map<String, dynamic> caps) {
    _capabilities = caps;
    _send({'type': 'capabilities', 'value': caps});
  }

  void sendOrientationAngle(int angle) {
    _orientationAngle = angle;
    _send({'type': 'orientation_change', 'angle': angle});
  }

  /// Phone → desktop remote control (e.g. switch desktop camera, next slide).
  void sendControl(String action, [dynamic value]) {
    _send({'type': 'control', 'action': action, 'value': value});
  }

  void _scheduleReconnect() {
    if (_status == ConnectionStatus.idle) return;
    if (_reconnectTimer?.isActive ?? false) return;
    if (_reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
      _log('Max reconnect attempts reached');
      setStatus(ConnectionStatus.error);
      return;
    }
    _reconnectAttempts++;
    final delayMs = (1000 * (1 << (_reconnectAttempts - 1))).clamp(1000, 16000);
    _log('Reconnecting (attempt $_reconnectAttempts/$MAX_RECONNECT_ATTEMPTS) in ${delayMs}ms');
    setStatus(ConnectionStatus.reconnecting);

    _pingTimer?.cancel();
    try { _ws?.sink.close(); } catch (_) {}
    _ws = null;

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () async {
      if (_host.isEmpty) return;
      final ok = await connect(_host, _controlPort, _videoPort);
      if (!ok) _scheduleReconnect();
    });
  }

  void _reconnectVideoStream() {
    if (_status != ConnectionStatus.connected) return;
    if (_host.isEmpty || _deviceId.isEmpty) return;
    _log('Reconnecting video stream...');
    _connectVideoStream(_host, _videoPort, _deviceId).catchError((e) {
      _log('Video reconnect failed: $e');
      Future.delayed(const Duration(seconds: 2), _reconnectVideoStream);
    });
  }

  void setStatus(ConnectionStatus status) {
    _status = status;
    notifyListeners();
  }

  void disconnect() {
    try {
      _log('Disconnecting...');
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _pingTimer?.cancel();
      _pingTimer = null;
      try { _ws?.sink.close(); } catch (_) {}
      _ws = null;
      try { _videoSocket?.destroy(); } catch (_) {}
      _videoSocket = null;
      _videoHeaderSent = false;
      _deviceId = '';
      _reconnectAttempts = 0;
      _framesSent = 0;
      _framesDropped = 0;
      _latencyMs = 0;
      _quality = LinkQuality.disconnected;
    } catch (e) {
      _log('Error disconnecting: $e');
    }
    setStatus(ConnectionStatus.idle);
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
