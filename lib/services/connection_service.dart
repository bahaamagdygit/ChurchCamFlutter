import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'video_protocol.dart';

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

/// A camera available on the desktop (from welcome / desktop_state).
/// `id` carries the desktop's switch prefix (e.g. `usb:<deviceId>` or `ip:<id>`).
class DesktopCamera {
  final String id;
  final String label;
  final String kind; // 'usb' | 'ip' | 'mobile' | ''
  const DesktopCamera({required this.id, required this.label, this.kind = ''});
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
  static const int PING_INTERVAL_MS = 1000;
  // Heartbeat liveness: 3 consecutive unanswered pings → force reconnect (Section 2).
  int _missedPongs = 0;
  static const int MAX_MISSED_PONGS = 3;

  // Capabilities advertised to the desktop during handshake.
  Map<String, dynamic> _capabilities = {};
  // Current phone orientation angle (0/90/180/270) sent on hello + on change.
  int _orientationAngle = 0;

  // Video codecs this build can SEND, best-first. Phase 0 advertises 'mjpeg'
  // only; when the native H.264 encoder lands this becomes ['h264','mjpeg'] and
  // the desktop auto-selects h264 if it can decode. The negotiated result from
  // the welcome message is stored in [_videoCodec].
  List<String> _supportedVideoCodecs = const ['mjpeg'];
  String _videoCodec = 'mjpeg';
  String get videoCodec => _videoCodec;

  /// Override the advertised codec list (e.g. enable 'h264' once the native
  /// encoder is wired up). Best-first order.
  void setSupportedVideoCodecs(List<String> codecs) {
    if (codecs.isNotEmpty) _supportedVideoCodecs = List.of(codecs);
  }

  // Reading text overlay pushed from the desktop.
  String _readingText = '';
  List<String> _readingLangs = const [];

  // Desktop state (from welcome / desktop_state).
  List<DesktopCamera> _desktopCameras = const [];
  String _activeCameraLabel = '';
  bool _streamLive = false;
  bool _recording = false;

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
  List<DesktopCamera> get desktopCameras => _desktopCameras;
  String get activeCameraLabel => _activeCameraLabel;
  bool get streamLive => _streamLive;
  bool get recording => _recording;

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

  /// Supplies the full current state for the reconnect "state restore" handshake
  /// (device name, capabilities, orientation, zoom, filters, colors). Set by the
  /// CameraScreen so a reconnect immediately restores the desktop's view.
  Map<String, dynamic> Function()? stateProvider;

  /// Set before connecting so the desktop shows a friendly name + the right
  /// zoom slider range.
  void configure({String? deviceName, Map<String, dynamic>? capabilities, int? orientationAngle}) {
    if (deviceName != null && deviceName.trim().isNotEmpty) {
      _deviceName = deviceName.trim();
    }
    if (capabilities != null) _capabilities = capabilities;
    if (orientationAngle != null) _orientationAngle = orientationAngle;
  }

  // ── Mobile → desktop controls (Section 5) ────────────────────────────────────
  // NB: these use the action names the desktop actually handles (see App.tsx
  // onMobileControl): select_camera, set_zoom, toggle_text, next_slide,
  // prev_slide, start_stream, stop_stream, start_recording, stop_recording,
  // cut_to_black.
  void selectDesktopCamera(String deviceId) => sendControl('select_camera', deviceId);
  void desktopZoom(double zoom) => sendControl('set_zoom', zoom);
  void toggleReadingOverlay(bool visible) => sendControl('toggle_text', visible);
  void nextSlide() => sendControl('next_slide');
  void prevSlide() => sendControl('prev_slide');
  void startStream() => sendControl('start_stream');
  void stopStream() => sendControl('stop_stream');
  void startRecording() => sendControl('start_recording');
  void stopRecording() => sendControl('stop_recording');
  void cutToBlack(bool active) => sendControl('cut_to_black', active);

  /// Confirm an applied control back to the desktop (Section 4).
  void confirmControl(String controlType, dynamic appliedValue) {
    _send({'type': 'control_ack', 'control': controlType, 'value': appliedValue});
  }

  /// Report an unsupported / failed control (Section 11).
  void reportUnsupported(String controlType, String reason) {
    _send({'type': 'control_error', 'control': controlType, 'reason': reason});
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
      // Merge any extra state (zoom, filters, colors) so a reconnect restores
      // the desktop's view without operator action.
      final hello = <String, dynamic>{
        'type': 'hello',
        'name': _deviceName,
        'platform': 'Android',
        'capabilities': _capabilities,
        'orientationAngle': _orientationAngle,
        'videoCodecs': _supportedVideoCodecs,
      };
      try {
        final extra = stateProvider?.call();
        if (extra != null) hello.addAll(extra);
      } catch (_) {}
      _send(hello);

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
        // Codec the desktop selected for this session (defaults to mjpeg for
        // older desktops that don't send the field).
        _videoCodec = (msg['videoCodec'] ?? 'mjpeg').toString();
        // Optional desktop state in the welcome (Section 3).
        if (msg['streamStatus'] != null) _streamLive = msg['streamStatus'] == 'live';
        if (msg['recordingStatus'] != null) _recording = msg['recordingStatus'] == 'recording';
        if (msg['desktopCameras'] is List) {
          _desktopCameras = (msg['desktopCameras'] as List)
              .whereType<Map>()
              .map((m) => DesktopCamera(
                    id: (m['id'] ?? '').toString(),
                    label: (m['label'] ?? '').toString(),
                  ))
              .toList();
        }
        _log('Welcome: deviceId=$_deviceId videoPort=$_videoPort');
        notifyListeners();
        onWelcome();
        break;

      case 'ping':
        // Desktop heartbeat — echo a pong with the same timestamp.
        _send({'type': 'pong', 't': msg['t']});
        break;

      case 'pong':
        _missedPongs = 0;
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

      case 'desktop_state': {
        final v = msg['value'];
        if (v is Map) {
          if (v['streamStatus'] != null) _streamLive = v['streamStatus'] == 'live';
          if (v['recordingStatus'] != null) _recording = v['recordingStatus'] == 'recording';
          if (v['activeCameraLabel'] != null) _activeCameraLabel = v['activeCameraLabel'].toString();
          // Live list of every camera the desktop can switch to (usb:/ip: ids).
          if (v['availableCameras'] is List) {
            _desktopCameras = (v['availableCameras'] as List)
                .whereType<Map>()
                .map((m) => DesktopCamera(
                      id: (m['id'] ?? '').toString(),
                      label: (m['label'] ?? '').toString(),
                      kind: (m['kind'] ?? '').toString(),
                    ))
                .where((c) => c.id.isNotEmpty)
                .toList();
          }
          notifyListeners();
        }
        _emitCommand(RemoteCommand('desktop_state', v));
        break;
      }

      case 'filter_state':
        // Desktop pushed a filter update for this camera — hand to listeners.
        _emitCommand(RemoteCommand('filter_state', msg['value']));
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

  // Backpressure tracking: how many bytes we've handed to the socket that
  // haven't been flushed to the OS yet. If this grows, the network is the
  // bottleneck and we should drop frames rather than queue them (queueing adds
  // latency that never recovers).
  int _pendingBytes = 0;
  bool _flushing = false;
  // Allow at most ~2 frames' worth of un-flushed data before we start dropping.
  static const int _maxPendingBytes = 256 * 1024;

  /// True when the socket can accept another frame without building a backlog.
  /// The camera calls this before encoding so it never wastes CPU on a frame
  /// the network can't take.
  bool get canAcceptFrame =>
      _videoSocket != null && _videoHeaderSent && _pendingBytes < _maxPendingBytes;

  /// Current un-flushed video bytes — used by the adaptive-quality controller.
  int get pendingVideoBytes => _pendingBytes;

  // ── Send-bitrate metric (rolling 1s window) ──────────────────────────────────
  int _bitrateWindowBytes = 0;
  int _bitrateWindowStartMs = 0;
  int _sendBitrateKbps = 0;
  /// Measured outgoing video bitrate in kbps (rolling ~1s). For the metrics HUD.
  int get sendBitrateKbps => _sendBitrateKbps;

  void _accountBitrate(int bytes) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_bitrateWindowStartMs == 0) _bitrateWindowStartMs = now;
    _bitrateWindowBytes += bytes;
    final elapsed = now - _bitrateWindowStartMs;
    if (elapsed >= 1000) {
      _sendBitrateKbps = ((_bitrateWindowBytes * 8) / elapsed).round(); // bits/ms == kbits/s
      _bitrateWindowBytes = 0;
      _bitrateWindowStartMs = now;
    }
  }

  /// Send one JPEG video frame: 4-byte big-endian length prefix + JPEG bytes.
  /// Frames are dropped (counted) when the channel isn't ready or backlogged.
  void sendFrame(Uint8List jpeg) {
    final sock = _videoSocket;
    if (sock == null || !_videoHeaderSent) {
      _framesDropped++;
      return;
    }
    if (_pendingBytes >= _maxPendingBytes) {
      // Network can't keep up — drop to stay realtime.
      _framesDropped++;
      return;
    }
    try {
      final len = jpeg.length;
      // Single contiguous write (prefix + payload) → one syscall, less overhead.
      final out = Uint8List(4 + len);
      out[0] = (len >> 24) & 0xFF;
      out[1] = (len >> 16) & 0xFF;
      out[2] = (len >> 8) & 0xFF;
      out[3] = len & 0xFF;
      out.setRange(4, 4 + len, jpeg);

      sock.add(out);
      _pendingBytes += out.length;
      _framesSent++;
      _accountBitrate(out.length);

      // Flush and clear the pending counter when the OS has taken the data.
      if (!_flushing) {
        _flushing = true;
        sock.flush().then((_) {
          _pendingBytes = 0;
          _flushing = false;
        }).catchError((_) {
          _pendingBytes = 0;
          _flushing = false;
        });
      }

      if (_framesSent % 24 == 0) notifyListeners();
    } catch (e) {
      _framesDropped++;
      _pendingBytes = 0;
      _flushing = false;
      _log('sendFrame failed: $e');
    }
  }

  /// Send one H.264 access unit as a v2 wire frame (16-byte header + Annex-B).
  /// [type] 0=config 1=key 2=delta. Same drop-on-backlog policy as sendFrame.
  void sendV2Frame({
    required int type,
    required Uint8List payload,
    required int captureTsUs,
    bool mirror = false,
    int rotation = 0,
  }) {
    final sock = _videoSocket;
    if (sock == null || !_videoHeaderSent) { _framesDropped++; return; }
    // Never drop config/key on backlog (they gate decodability); only deltas.
    if (type == 2 && _pendingBytes >= _maxPendingBytes) { _framesDropped++; return; }
    try {
      final out = encodeV2Frame(
        type: type == 0
            ? V2FrameType.config
            : type == 1
                ? V2FrameType.key
                : V2FrameType.delta,
        payload: payload,
        captureTsUs: captureTsUs,
        mirror: mirror,
        rotation: rotation,
      );
      sock.add(out);
      _pendingBytes += out.length;
      _framesSent++;
      _accountBitrate(out.length);
      if (!_flushing) {
        _flushing = true;
        sock.flush().then((_) {
          _pendingBytes = 0;
          _flushing = false;
        }).catchError((_) {
          _pendingBytes = 0;
          _flushing = false;
        });
      }
      if (_framesSent % 30 == 0) notifyListeners();
    } catch (e) {
      _framesDropped++;
      _pendingBytes = 0;
      _flushing = false;
      _log('sendV2Frame failed: $e');
    }
  }

  void _startPing() {
    _pingTimer?.cancel();
    _missedPongs = 0;
    _pingTimer = Timer.periodic(
      const Duration(milliseconds: PING_INTERVAL_MS),
      (timer) {
        if (_ws == null) {
          timer.cancel();
          return;
        }
        // Count this ping as "unanswered" until a pong resets it. Three in a
        // row with no reply → the link is dead, force a reconnect.
        _missedPongs++;
        if (_missedPongs > MAX_MISSED_PONGS) {
          _log('Heartbeat timeout ($_missedPongs missed) — forcing reconnect');
          timer.cancel();
          _scheduleReconnect();
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

  // Exponential backoff: 500ms → ×2 → cap 5000ms, retry indefinitely (Section 2).
  static const int RECONNECT_BASE_MS = 500;
  static const int RECONNECT_MAX_MS = 5000;

  void _scheduleReconnect() {
    if (_status == ConnectionStatus.idle) return; // user disconnected
    if (_reconnectTimer?.isActive ?? false) return;

    _reconnectAttempts++;
    final raw = RECONNECT_BASE_MS * (1 << (_reconnectAttempts - 1).clamp(0, 16));
    final delayMs = raw.clamp(RECONNECT_BASE_MS, RECONNECT_MAX_MS);
    _log('Reconnecting (attempt $_reconnectAttempts) in ${delayMs}ms');
    setStatus(ConnectionStatus.reconnecting);

    _pingTimer?.cancel();
    try { _ws?.sink.close(); } catch (_) {}
    _ws = null;

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () async {
      if (_host.isEmpty || _status == ConnectionStatus.idle) return;
      final ok = await connect(_host, _controlPort, _videoPort);
      if (!ok) _scheduleReconnect(); // keep trying forever
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
