import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:logger/logger.dart';
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

class ConnectionService extends ChangeNotifier {
  static const int CONTROL_PORT = 8765;
  static const int VIDEO_PORT = 8766;
  static const int DISCOVERY_PORT = 8767;

  final logger = Logger();

  String _host = '';
  int _controlPort = CONTROL_PORT;
  int _videoPort = VIDEO_PORT;
  String _deviceId = '';

  WebSocketChannel? _ws;
  Socket? _videoSocket;
  ConnectionStatus _status = ConnectionStatus.idle;
  int _latencyMs = 0;
  int _framesSent = 0;
  int _framesDropped = 0;
  LinkQuality _quality = LinkQuality.disconnected;

  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  int _reconnectAttempts = 0;
  static const int MAX_RECONNECT_ATTEMPTS = 5;
  static const int HEARTBEAT_INTERVAL = 1000;
  static const int HEARTBEAT_TIMEOUT = 3000;

  // Getters
  ConnectionStatus get status => _status;
  int get latencyMs => _latencyMs;
  int get framesSent => _framesSent;
  int get framesDropped => _framesDropped;
  String get deviceId => _deviceId;
  LinkQuality get quality => _quality;

  Future<bool> connect(String host, int controlPort, int videoPort) async {
    try {
      _host = host;
      _controlPort = controlPort;
      _videoPort = videoPort;

      setStatus(ConnectionStatus.connecting);

      logger.i('[ConnectionService] Connecting to $host');
      logger.i('[ConnectionService] Control port: $controlPort');
      logger.i('[ConnectionService] Video port: $videoPort');

      // Connect WebSocket control channel first
      final wsUrl = 'ws://$host:$controlPort';
      logger.i('[ConnectionService] Connecting control WebSocket: $wsUrl');

      try {
        final receivedDeviceId = await _connectWebSocket(wsUrl);
        logger.i('[ConnectionService] Control WebSocket handshake complete ✓, deviceId=$receivedDeviceId');

        // Check if video port is accessible
        logger.i('[ConnectionService] Checking video port $videoPort...');
        final videoPortAccessible = await _checkPortAccessible(host, videoPort, 2000);
        if (!videoPortAccessible) {
          logger.w('[ConnectionService] WARNING: Video port $videoPort may not be accessible');
          logger.w('[ConnectionService] Make sure desktop app is running and listening on video port');
        }

        // Connect video stream
        await _connectVideoStream(host, videoPort, receivedDeviceId);

        setStatus(ConnectionStatus.connected);
        _reconnectAttempts = 0;
        logger.i('[ConnectionService] Connection complete ✓');

        return true;
      } catch (e) {
        logger.e('[ConnectionService] Connection failed: $e');
        setStatus(ConnectionStatus.error);
        return false;
      }
    } catch (e) {
      logger.e('[ConnectionService] Unexpected error during connect: $e');
      setStatus(ConnectionStatus.error);
      return false;
    }
  }

  Future<bool> _checkPortAccessible(String host, int port, int timeout) async {
    try {
      final startTime = DateTime.now().millisecondsSinceEpoch;

      try {
        final socket = await Socket.connect(host, port,
          timeout: Duration(milliseconds: timeout));
        socket.destroy();

        final elapsed = DateTime.now().millisecondsSinceEpoch - startTime;
        logger.i('[ConnectionService] Port check $host:$port: OPEN (${elapsed}ms)');
        return true;
      } on SocketException {
        logger.i('[ConnectionService] Port check $host:$port: CLOSED');
        return false;
      }
    } catch (e) {
      logger.e('[ConnectionService] Port check error for $host:$port: $e');
      return false;
    }
  }

  Future<String> _connectWebSocket(String wsUrl) async {
    final completer = Completer<String>();
    var resolved = false;

    final timeout = Timer(Duration(seconds: 10), () {
      if (!resolved) {
        resolved = true;
        if (!completer.isCompleted) {
          completer.completeError(Exception('WebSocket connection timeout'));
        }
      }
    });

    try {
      _ws = WebSocketChannel.connect(Uri.parse(wsUrl));

      _ws!.stream.listen((data) {
        try {
          final msg = jsonDecode(data);
          logger.d('[ConnectionService] WebSocket message: ${msg['type']}');

          if (msg['type'] == 'welcome') {
            _deviceId = msg['deviceId'] ?? '';
            logger.i('[ConnectionService] Welcome received, deviceId=$_deviceId');
            if (!resolved) {
              resolved = true;
              timeout.cancel();
              completer.complete(_deviceId);
            }
          } else if (msg['type'] == 'pong') {
            if (msg['t'] is int) {
              _latencyMs = DateTime.now().millisecondsSinceEpoch - (msg['t'] as int);
              _quality = qualityFor(_latencyMs);
              notifyListeners();
            }
          } else if (msg['type'] == 'command') {
            logger.i('[ConnectionService] Command: ${msg['action']}');
          }
        } catch (e) {
          logger.w('[ConnectionService] Error parsing message: $e');
        }
      },
      onError: (error) {
        logger.e('[ConnectionService] WebSocket error: $error');
        if (!resolved) {
          resolved = true;
          timeout.cancel();
          completer.completeError(error);
        }
        setStatus(ConnectionStatus.error);
        _reconnect();
      },
      onDone: () {
        logger.i('[ConnectionService] WebSocket closed');
        if (!resolved) {
          resolved = true;
          timeout.cancel();
          completer.completeError(Exception('WebSocket closed'));
        }
        setStatus(ConnectionStatus.reconnecting);
        _reconnect();
      });

      // Start heartbeat
      _startHeartbeat();

      return completer.future;
    } catch (e) {
      logger.e('[ConnectionService] WebSocket connection error: $e');
      if (!resolved) {
        resolved = true;
        timeout.cancel();
        completer.completeError(e);
      }
      rethrow;
    }
  }


  Future<void> _connectVideoStream(
    String host,
    int port,
    String deviceId,
  ) async {
    try {
      logger.i('[ConnectionService] Connecting video stream: $host:$port, deviceId=$deviceId');

      _videoSocket = await Socket.connect(host, port,
        timeout: const Duration(seconds: 5),
      );

      // Send 32-byte device ID header
      final header = utf8.encode(deviceId);
      final headerBytes = List<int>.filled(32, 0);
      for (int i = 0; i < header.length && i < 32; i++) {
        headerBytes[i] = header[i];
      }
      _videoSocket!.add(headerBytes);

      logger.i('[ConnectionService] Video stream connected ✓');

      _videoSocket!.listen(
        (data) {
          // Video frames arrive here
          _framesSent++;
          logger.d('[ConnectionService] Frame received, total: $_framesSent');
        },
        onError: (error) {
          logger.e('[ConnectionService] Video socket error: $error');
          _reconnectVideoStream();
        },
        onDone: () {
          logger.w('[ConnectionService] Video socket closed');
          _reconnectVideoStream();
        },
      );
    } catch (e) {
      logger.e('[ConnectionService] Video connection failed: $e');
      logger.e('[ConnectionService] Ensure: 1) Desktop app running 2) Port $port open 3) Same network');
      throw e;
    }
  }

  void _startHeartbeat() {
    // Cancel existing heartbeat timer
    _heartbeatTimer?.cancel();

    _heartbeatTimer = Timer.periodic(Duration(milliseconds: HEARTBEAT_INTERVAL), (timer) {
      if (_ws != null) {
        try {
          _ws!.sink.add(jsonEncode({
            'type': 'ping',
            't': DateTime.now().millisecondsSinceEpoch,
          }));
        } catch (e) {
          logger.w('[ConnectionService] Error sending ping: $e');
          timer.cancel();
        }
      } else {
        timer.cancel();
      }
    });
  }

  void _reconnect() {
    if (_reconnectTimer?.isActive ?? false) return;
    if (_reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
      logger.w('[ConnectionService] Max reconnection attempts reached');
      setStatus(ConnectionStatus.error);
      return;
    }

    _reconnectAttempts++;
    final delay = (1000 * pow(2, _reconnectAttempts - 1)).toInt();
    final clampedDelay = delay.clamp(0, 16000);

    logger.i('[ConnectionService] Reconnecting (attempt $_reconnectAttempts/$MAX_RECONNECT_ATTEMPTS) in ${clampedDelay}ms...');

    setStatus(ConnectionStatus.reconnecting);

    _reconnectTimer = Timer(Duration(milliseconds: clampedDelay), () async {
      if (_host.isNotEmpty) {
        final result = await connect(_host, _controlPort, _videoPort);
        if (!result) {
          _reconnect();
        }
      }
    });
  }

  void _reconnectVideoStream() {
    if (_host.isNotEmpty && _deviceId.isNotEmpty) {
      logger.i('[ConnectionService] Reconnecting video stream...');
      _connectVideoStream(_host, _videoPort, _deviceId).catchError((e) {
        logger.e('[ConnectionService] Video reconnect failed: $e');
        Future.delayed(Duration(seconds: 2), _reconnectVideoStream);
      });
    }
  }

  void sendCapabilities(Map<String, dynamic> caps) {
    try {
      if (_ws != null) {
        _ws!.sink.add(jsonEncode({
          'type': 'capabilities',
          'value': caps,
        }));
        logger.i('[ConnectionService] Capabilities sent');
      }
    } catch (e) {
      logger.e('[ConnectionService] Error sending capabilities: $e');
    }
  }

  void sendOrientationAngle(int angle) {
    try {
      if (_ws != null) {
        _ws!.sink.add(jsonEncode({
          'type': 'orientation',
          'angle': angle,
        }));
        logger.i('[ConnectionService] Orientation sent: $angle');
      }
    } catch (e) {
      logger.e('[ConnectionService] Error sending orientation: $e');
    }
  }

  void setStatus(ConnectionStatus status) {
    _status = status;
    notifyListeners();
  }

  void disconnect() {
    try {
      logger.i('[ConnectionService] Disconnecting...');

      _reconnectTimer?.cancel();
      _reconnectTimer = null;

      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;

      _ws?.sink.close();
      _ws = null;

      _videoSocket?.close();
      _videoSocket = null;

      _deviceId = '';
      _reconnectAttempts = 0;

      logger.i('[ConnectionService] Disconnect complete ✓');
    } catch (e) {
      logger.e('[ConnectionService] Error disconnecting: $e');
    }
    setStatus(ConnectionStatus.idle);
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
