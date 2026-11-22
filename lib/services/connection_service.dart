import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'video_protocol.dart';
import 'storage.dart' show loadClientId;

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

/// A camera-switch transition offered by the desktop.
class TransitionOption {
  final String id;
  final String label;
  final String labelAr;
  const TransitionOption({required this.id, required this.label, this.labelAr = ''});
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
  String? _clientId;

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
  // Tolerant of brief stalls (large H.264 keyframes can delay a pong). 6 misses
  // (≈6s) before forcing a reconnect, matching the desktop side — prevents a
  // reconnect spiral that restarts the encoder and floods the link.
  static const int MAX_MISSED_PONGS = 4;

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
  String _activeCameraId = '';
  String _previewCameraId = '';
  String _switchTransition = '';
  List<TransitionOption> _transitions = const [];
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
  /// Switch id of the camera currently on air ('usb:…', 'ip:…', 'mobile:…').
  String get activeCameraId => _activeCameraId;
  /// Switch id that means "this phone" on the desktop.
  String get selfCameraId => _deviceId.isEmpty ? '' : 'mobile:$_deviceId';
  /// True when THIS phone is the live program source (drives the tally light).
  bool get isSelfLive => _deviceId.isNotEmpty && _activeCameraId == selfCameraId;
  /// The director has cued THIS phone as the next camera (green tally).
  bool get isSelfCued => _deviceId.isNotEmpty && _previewCameraId == selfCameraId && !isSelfLive;
  String get previewCameraId => _previewCameraId;
  /// Quick reply from the camera operator to the director ("Ready", "OK"…).
  void sendDirectorReply(String text) => sendControl('director_reply', text);
  String get switchTransition => _switchTransition;
  List<TransitionOption> get transitions => _transitions;
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

  /// Called whenever the video socket (re)connects. The camera screen uses this
  /// to force an H.264 config+keyframe so a freshly-attached desktop decoder can
  /// initialize immediately.
  void Function()? onVideoReady;

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
  void selectDesktopCamera(String deviceId) {
    // Optimistic: light the tally immediately; desktop_state confirms.
    _activeCameraId = deviceId;
    notifyListeners();
    sendControl('select_camera', deviceId);
  }
  void setSwitchTransition(String id) {
    _switchTransition = id;
    notifyListeners();
    sendControl('set_transition', id);
  }
  /// Phone → desktop live state (zoom, Smart Zoom status) for the desktop UI.
  void sendPhoneState(Map<String, dynamic> state) => _send({'type': 'phone_state', 'value': state});
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

      // Reconnects keep showing "Reconnecting" (not "Connecting") in the UI.
      if (_status != ConnectionStatus.reconnecting) setStatus(ConnectionStatus.connecting);
      _log('Connecting to $host (control=$controlPort, video=$videoPort)');
      _clientId ??= await loadClientId();

      // Fully drop any previous sockets first. Leaving them to close "whenever"
      // is what let a stale socket's late close tear down the fresh connection.
      _dropSockets();

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

    final timeout = Timer(const Duration(seconds: 5), () {
      if (!resolved) {
        resolved = true;
        if (!completer.isCompleted) {
          completer.completeError(Exception('WebSocket connection timeout'));
        }
      }
    });

    try {
      final ch = WebSocketChannel.connect(Uri.parse(wsUrl));
      _ws = ch;

      // Every handler checks it still belongs to the CURRENT channel. A
      // replaced channel finishing late used to call _scheduleReconnect(),
      // which closed the brand-new connection — a reconnect loop.
      ch.stream.listen(
        (data) {
          if (!identical(_ws, ch)) return;
          _onControlMessage(data, () {
            if (!resolved) {
              resolved = true;
              timeout.cancel();
              completer.complete(_deviceId);
            }
          });
        },
        onError: (error) {
          if (!identical(_ws, ch)) return;
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
          if (!identical(_ws, ch)) return;
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
        // Stable identity → the desktop gives us back the same deviceId on a
        // reconnect, so this phone stays on air through a Wi-Fi blip.
        'clientId': _clientId,
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
          if (v['activeCameraId'] != null) _activeCameraId = v['activeCameraId'].toString();
          if (v.containsKey('previewCameraId')) _previewCameraId = (v['previewCameraId'] ?? '').toString();
          if (v['switchTransition'] != null) _switchTransition = v['switchTransition'].toString();
          if (v['transitions'] is List) {
            _transitions = (v['transitions'] as List)
                .whereType<Map>()
                .map((m) => TransitionOption(
                      id: (m['id'] ?? '').toString(),
                      label: (m['label'] ?? '').toString(),
                      labelAr: (m['labelAr'] ?? '').toString(),
                    ))
                .where((t) => t.id.isNotEmpty)
                .toList();
          }
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

      case 'rx_stats':
        // Desktop receive/decoder health for the ABR controller.
        _emitCommand(RemoteCommand('rx_stats', msg['value']));
        break;
    }
  }

  Future<void> _connectVideoStream(String host, int port, String deviceId) async {
    _videoHeaderSent = false;
    // Never leave two video sockets alive: the old one is replaced, not leaked.
    final old = _videoSocket;
    _videoSocket = null;
    try { old?.destroy(); } catch (_) {}
    _pendingBytes = 0;
    _flushing = false;
    try {
      _log('Connecting video stream: $host:$port');
      final sock = await Socket.connect(host, port, timeout: const Duration(seconds: 4));
      sock.setOption(SocketOption.tcpNoDelay, true);
      _videoSocket = sock;

      // Send the 32-byte ASCII deviceId header (zero-padded).
      final idBytes = utf8.encode(deviceId);
      final header = Uint8List(32);
      for (int i = 0; i < idBytes.length && i < 32; i++) {
        header[i] = idBytes[i];
      }
      sock.add(header);
      _videoHeaderSent = true;
      _log('Video stream connected ✓ (header sent)');

      // H.264: a fresh video socket has no decoder state on the desktop. Ask the
      // encoder to emit a new config (SPS/PPS) + keyframe immediately so the
      // desktop decoder can (re)initialize without waiting ~1s for the next IDR.
      try { onVideoReady?.call(); } catch (_) {}

      // Handlers only act if this is still THE video socket — a superseded
      // socket closing late used to null out the new one (frames silently
      // dropped) and spawn yet another connection.
      void lost(String why) {
        if (!identical(_videoSocket, sock)) return;
        _log('Video socket $why');
        _videoSocket = null;
        _videoHeaderSent = false;
        _pendingBytes = 0;
        _flushing = false;
        _reconnectVideoStream();
      }
      sock.listen((_) {}, onError: (error) => lost('error: $error'), onDone: () => lost('closed'), cancelOnError: true);
    } catch (e) {
      _videoSocket = null;
      _videoHeaderSent = false;
      _log('Video connection failed: $e');
      rethrow;
    }
  }

  /// Close both sockets without triggering reconnect logic (their handlers
  /// see they're no longer current and stay quiet).
  void _dropSockets() {
    final ws = _ws;
    _ws = null;
    try { ws?.sink.close(); } catch (_) {}
    final v = _videoSocket;
    _videoSocket = null;
    _videoHeaderSent = false;
    _pendingBytes = 0;
    _flushing = false;
    try { v?.destroy(); } catch (_) {}
  }

  // Backpressure tracking: how many bytes we've handed to the socket that
  // haven't been flushed to the OS yet. If this grows, the network is the
  // bottleneck and we should drop frames rather than queue them (queueing adds
  // latency that never recovers).
  int _pendingBytes = 0;
  bool _flushing = false;
  // LOW-LATENCY: allow only ~1 frame of un-flushed data. The moment the socket
  // is behind by more than one frame, we DROP new frames instead of queueing —
  // queued frames are stale by the time they arrive, which is exactly the delay
  // we're eliminating. Smaller = fresher picture, zero accumulating lag.
  static const int _maxPendingBytes = 96 * 1024;

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

  /// One 20 ms PCM chunk (s16le mono 48 kHz) as a v2 audio frame. Audio is
  /// tiny next to video, so it's only dropped when the link is badly backed up
  /// — a gap in sound is far more noticeable than a dropped video frame.
  final int _audioEpochUs = DateTime.now().microsecondsSinceEpoch;
  void sendAudio(Uint8List pcm) {
    final sock = _videoSocket;
    if (sock == null || !_videoHeaderSent) return;
    if (_pendingBytes >= _maxPendingBytes * 6) return;
    try {
      final out = encodeV2Frame(
        type: V2FrameType.audio,
        payload: pcm,
        captureTsUs: DateTime.now().microsecondsSinceEpoch - _audioEpochUs,
      );
      sock.add(out);
      _pendingBytes += out.length;
      if (!_flushing) {
        _flushing = true;
        sock.flush().then((_) { _pendingBytes = 0; _flushing = false; })
            .catchError((_) { _pendingBytes = 0; _flushing = false; });
      }
    } catch (_) {}
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

  /// Phone → desktop device status (battery, wifi signal) for the device list.
  void sendDeviceStatus(Map<String, dynamic> status) {
    _send({'type': 'device_status', 'value': status});
  }

  /// Phone → desktop remote control (e.g. switch desktop camera, next slide).
  void sendControl(String action, [dynamic value]) {
    _send({'type': 'control', 'action': action, 'value': value});
  }

  // Exponential backoff: 250ms → ×2 → cap 2000ms, retry indefinitely. Short
  // cap on purpose: the desktop holds this phone's session (and its place on
  // air) for 20s, so getting back fast matters more than politeness.
  static const int RECONNECT_BASE_MS = 250;
  static const int RECONNECT_MAX_MS = 2000;

  void _scheduleReconnect() {
    if (_status == ConnectionStatus.idle) return; // user disconnected
    if (_reconnectTimer?.isActive ?? false) return;

    _reconnectAttempts++;
    final raw = RECONNECT_BASE_MS * (1 << (_reconnectAttempts - 1).clamp(0, 16));
    final delayMs = raw.clamp(RECONNECT_BASE_MS, RECONNECT_MAX_MS);
    _log('Reconnecting (attempt $_reconnectAttempts) in ${delayMs}ms');
    setStatus(ConnectionStatus.reconnecting);

    _pingTimer?.cancel();
    _dropSockets();

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () async {
      if (_host.isEmpty || _status == ConnectionStatus.idle) return;
      final ok = await connect(_host, _controlPort, _videoPort);
      if (!ok) _scheduleReconnect(); // keep trying forever
    });
  }

  bool _videoReconnecting = false;
  void _reconnectVideoStream() {
    if (_status != ConnectionStatus.connected) return;
    if (_host.isEmpty || _deviceId.isEmpty) return;
    if (_videoReconnecting) return; // one retry loop at a time
    _videoReconnecting = true;
    _log('Reconnecting video stream...');
    _connectVideoStream(_host, _videoPort, _deviceId).then((_) {
      _videoReconnecting = false;
    }).catchError((e) {
      _videoReconnecting = false;
      _log('Video reconnect failed: $e');
      Future.delayed(const Duration(milliseconds: 600), _reconnectVideoStream);
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
