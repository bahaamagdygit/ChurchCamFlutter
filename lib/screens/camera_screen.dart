import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:gal/gal.dart';
import '../services/connection_service.dart';
import '../services/camera_service.dart';
import '../services/abr_controller.dart';
import '../services/device_status_service.dart';
import '../services/orientation_service.dart';
import '../services/storage.dart';
import '../services/smart_framer.dart';
import '../services/audio_service.dart';
import '../models/camera_filters.dart';
import '../utils/permissions.dart';
import '../widgets/metrics_overlay.dart';
import '../widgets/filtered_preview.dart';
import '../ui/tokens.dart';
import '../ui/components.dart';
import 'control_screen.dart';
import 'settings_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  final CameraService _camera = CameraService();
  final OrientationService _orientation = OrientationService();
  final DeviceStatusService _deviceStatus = DeviceStatusService();
  Timer? _statusTimer;

  bool _permissionDenied = false;
  bool _initializing = true;
  String? _initError;

  CameraFilters _filters = CameraFilters.none;

  // Which side-panel tab is open (null = clean viewfinder).
  _Tab? _tab;

  // Pinch-to-zoom
  double _baseZoom = 1.0;
  bool _showZoomBar = false;
  Timer? _zoomBarTimer;

  // Smart Zoom: while this mode is on, tapping a person locks the shot on them.
  bool _smartMode = false;

  // Phone → desktop state report (zoom + Smart Zoom), throttled.
  Timer? _stateReportTimer;
  bool _stateReportQueued = false;

  // Focus ring
  Offset? _focusPoint;
  Timer? _focusTimer;

  Timer? _adaptiveTimer;
  ConnectionService? _conn;
  AbrController? _abr;
  bool _showMetrics = false;

  // Persisted settings (viewfinder aids, stabiliser, audio, codec).
  AppSettings _settings = const AppSettings();

  // Microphone → desktop.
  final AudioService _audio = AudioService();

  // Saved shots (camera presets).
  List<ShotPreset> _shots = [];
  String? _activeShotId;

  // Zebra / peaking overlay image (source orientation) + horizon level.
  final ValueNotifier<ui.Image?> _aidsImage = ValueNotifier<ui.Image?>(null);
  final ValueNotifier<double> _tilt = ValueNotifier<double>(0);
  StreamSubscription? _accelSub;

  // Director → camera operator message currently shown.
  String? _directorMsg;
  Timer? _directorTimer;

  // Backup-recording timer tick for the HUD.
  Timer? _isoTicker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _conn = context.read<ConnectionService>();
    _conn!.addCommandListener(_onRemoteCommand);
    _conn!.stateProvider = _buildStateRestore;
    _orientation.addListener(_onOrientation);
    _orientation.start();
    _deviceStatus.start();
    // Push battery + wifi to the desktop every 5s (and refresh the HUD).
    _deviceStatus.addListener(() { if (mounted) setState(() {}); });
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _conn?.sendDeviceStatus(_deviceStatus.toJson());
    });
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final granted = await requestCameraPermission();
    if (!mounted) return;
    if (!granted) {
      setState(() { _permissionDenied = true; _initializing = false; });
      return;
    }
    // Settings first: the capture resolution must be chosen before the camera
    // opens (re-opening mid-stream causes a reconnect storm).
    _settings = await loadSettings();
    _shots = await loadShots();
    _camera.setCaptureLongEdge(_settings.videoLongEdge);

    final ok = await _camera.initialize();
    if (!mounted) return;
    if (!ok) {
      setState(() { _initError = 'No camera available on this device.'; _initializing = false; });
      return;
    }

    // Viewfinder aids, stabiliser, horizon level, microphone, backup recording.
    _camera.zebraOn = _settings.zebraOn;
    _camera.peakingOn = _settings.peakingOn;
    _camera.onAids = _onAids;
    if (_settings.stabilize) _camera.setStabilize(true);
    if (_settings.levelOn) _startLevel();
    _audio.onPcm = (pcm) => _conn?.sendAudio(pcm);
    _audio.addListener(_onAudioLevel);
    if (_settings.audioEnabled) _setAudio(true, persist: false);
    _camera.onIsoFinished = _saveIsoToGallery;

    // Restore last filters for this camera.
    _filters = await loadFilters(_camera.lensDirection.name);

    _conn?.sendCapabilities(_camera.capabilities());
    _camera.onSmartZoomChanged = _reportPhoneState;
    _camera.onJpegFrame = (jpeg) => _conn?.sendFrame(jpeg);
    _camera.canSendFrame = () => _conn?.canAcceptFrame ?? false;
    _camera.onEncoderRestart = (reason) => _conn?.reportUnsupported('encoder', 'restarted: $reason');

    // H.264: forward each hardware access unit as a v2 wire frame, stamping the
    // current orientation + front-camera mirror so the desktop bakes them in.
    _camera.onH264Au = (au) {
      _conn?.sendV2Frame(
        type: au.type,
        payload: au.data,
        captureTsUs: au.ptsUs,
        mirror: _camera.lensDirection == CameraLensDirection.front,
        rotation: _orientation.angle,
      );
    };
    // If the desktop negotiated h264, switch the camera into hardware-encode
    // mode at the user's SELECTED resolution/fps (from Settings). Wrapped so an
    // encoder/camera failure falls back gracefully.
    if (_conn?.videoCodec == 'h264') {
      try {
        final s = await loadSettings();
        final longEdge = s.videoLongEdge; // 3840=4K … 640=360p
        final fps = s.videoFps;           // 30 | 60
        final bitrate = CameraService.bitrateFor(longEdge, fps);
        await _camera.setH264Mode(true,
            width: longEdge, height: (longEdge * 9 / 16).round(),
            fps: fps, bitrate: bitrate);
        // ABR may step DOWN under congestion but never above the user's choice.
        _abr = AbrController(
          startTier: AbrController.tierForLongEdge(longEdge, fps),
          onTierChange: (t) async {
            await _camera.setH264Mode(true, width: t.width, height: t.height, fps: t.fps, bitrate: t.bitrate);
            await _camera.requestH264Keyframe();
          },
          onBitrate: (br) => _camera.updateH264Bitrate(br),
        );
        debugPrint('[CameraScreen] H.264 start @ ${longEdge}p ${fps}fps ${bitrate ~/ 1000}kbps');
      } catch (e) {
        debugPrint('[CameraScreen] H.264 setup failed, staying on MJPEG: $e');
      }
    }
    // On every (re)connect of the video socket, force a fresh config+keyframe so
    // the desktop decoder can initialize without a stall.
    // A reconnect creates a fresh device on the desktop with no zoom/Smart Zoom
    // state, so re-send ours along with the keyframe request.
    _conn?.onVideoReady = () {
      _camera.requestH264Keyframe();
      _reportPhoneState();
    };

    await _camera.startStreaming();
    _camera.addListener(_onCameraChanged);

    // Adaptive-quality tick — 400ms for a fast reaction to link changes so the
    // quality recovers quickly and latency never accumulates (MJPEG backlog path).
    _adaptiveTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final abr = _abr;
      if (abr != null && _camera.isH264Mode) {
        abr.tick(pendingBytes: _conn?.pendingVideoBytes ?? 0, targetFps: _camera.targetFps);
      } else {
        _camera.reportBacklog(_conn?.pendingVideoBytes ?? 0);
      }
    });

    if (mounted) setState(() => _initializing = false);
    _reportPhoneState();
  }

  /// Tell the desktop the phone's current zoom + Smart Zoom state so its
  /// controls show the truth. Throttled to ≤ ~7/s with a trailing send.
  void _reportPhoneState() {
    if (_stateReportTimer?.isActive ?? false) { _stateReportQueued = true; return; }
    _sendPhoneStateNow();
    _stateReportTimer = Timer(const Duration(milliseconds: 150), () {
      if (_stateReportQueued) { _stateReportQueued = false; _sendPhoneStateNow(); }
    });
  }

  void _sendPhoneStateNow() {
    _conn?.sendPhoneState({
      'zoom': _camera.zoom,
      'zoomMin': _camera.minZoom,
      'zoomMax': _camera.maxZoom,
      'hardwareZoom': _camera.hasHardwareZoom,
      'smartZoom': _camera.smartZoomState(),
      'shots': _shots.map((s) => {'id': s.id, 'name': s.name}).toList(),
      'activeShot': _activeShotId,
      'isoRecording': _camera.isoRecording,
      'audio': _audio.running,
      'stabilize': _camera.stabilizeOn,
    });
  }

  // ── Settings persistence ────────────────────────────────────────────────────
  Future<void> _updateSettings(AppSettings s) async {
    setState(() => _settings = s);
    await saveSettings(s);
  }

  // ── Saved shots ─────────────────────────────────────────────────────────────
  Future<void> _saveShot(String name, {String? replaceId}) async {
    final id = replaceId ?? 'shot_${DateTime.now().millisecondsSinceEpoch}';
    final shot = _camera.captureShot(id, name);
    final list = [..._shots];
    final i = list.indexWhere((s) => s.id == id);
    if (i >= 0) { list[i] = shot; } else { list.add(shot); }
    setState(() { _shots = list; _activeShotId = id; });
    await saveShots(list);
    _reportPhoneState();
  }

  void _recallShot(ShotPreset s) {
    HapticFeedback.selectionClick();
    _camera.recallShot(s);
    setState(() { _activeShotId = s.id; _smartMode = false; });
    _reportPhoneState();
  }

  Future<void> _deleteShot(String id) async {
    final list = _shots.where((s) => s.id != id).toList();
    setState(() { _shots = list; if (_activeShotId == id) _activeShotId = null; });
    await saveShots(list);
    _reportPhoneState();
  }

  Future<void> _renameShot(String id, String name) async {
    final list = _shots.map((s) => s.id == id ? s.renamed(name) : s).toList();
    setState(() => _shots = list);
    await saveShots(list);
    _reportPhoneState();
  }

  // ── Microphone ──────────────────────────────────────────────────────────────
  Future<void> _setAudio(bool on, {bool persist = true}) async {
    if (on) {
      final ok = await _audio.start();
      if (!ok && mounted) _toast('Microphone unavailable — check the permission in Android settings.');
    } else {
      await _audio.stop();
    }
    if (persist) await _updateSettings(_settings.copyWith(audioEnabled: _audio.running));
    if (mounted) setState(() {});
    _reportPhoneState();
  }

  void _onAudioLevel() { if (mounted && (_tab == _Tab.studio)) setState(() {}); }

  // ── Viewfinder aids ─────────────────────────────────────────────────────────
  void _onAids(Uint8List rgba, int w, int h) {
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, (img) {
      if (!mounted) { img.dispose(); return; }
      final old = _aidsImage.value;
      _aidsImage.value = img;
      old?.dispose();
    });
  }

  Future<void> _setAids({bool? zebra, bool? peaking}) async {
    final s = _settings.copyWith(zebraOn: zebra, peakingOn: peaking);
    _camera.zebraOn = s.zebraOn;
    _camera.peakingOn = s.peakingOn;
    if (!s.zebraOn && !s.peakingOn) {
      final old = _aidsImage.value;
      _aidsImage.value = null;
      old?.dispose();
    }
    await _updateSettings(s);
  }

  void _startLevel() {
    _accelSub ??= accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen((e) {
      // Landscape: gravity lies along the device's x axis. The roll is the
      // angle of gravity off that axis; the sign follows which way up the
      // phone is held.
      final t = e.x >= 0 ? math.atan2(e.y, e.x) : math.atan2(-e.y, -e.x);
      _tilt.value = _tilt.value * 0.7 + t * 0.3; // smooth out sensor noise
    });
  }

  void _stopLevel() {
    _accelSub?.cancel();
    _accelSub = null;
  }

  Future<void> _setLevel(bool on) async {
    on ? _startLevel() : _stopLevel();
    await _updateSettings(_settings.copyWith(levelOn: on));
  }

  Future<void> _setStabilize(bool on) async {
    _camera.setStabilize(on);
    await _updateSettings(_settings.copyWith(stabilize: on));
    _reportPhoneState();
  }

  // ── Backup (ISO) recording ──────────────────────────────────────────────────
  bool _isoBusy = false;
  Future<void> _setIso(bool on) async {
    // Starting/stopping a recording takes a moment; a second tap (or a desktop
    // command) arriving meanwhile must not start a second, conflicting one.
    if (_isoBusy) return;
    _isoBusy = true;
    try { await _setIsoInner(on); } finally { _isoBusy = false; }
  }

  Future<void> _setIsoInner(bool on) async {
    if (on == _camera.isoRecording) return;
    if (on) {
      final ok = await _camera.startIsoRecording();
      if (!ok) {
        _toast(_camera.isH264Mode
            ? 'Backup recording isn\'t available in H.264 mode.'
            : 'This phone couldn\'t start a recording alongside the stream.');
      } else {
        HapticFeedback.mediumImpact();
        _isoTicker?.cancel();
        _isoTicker = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
      }
    } else {
      _isoTicker?.cancel();
      _isoTicker = null;
      final path = await _camera.stopIsoRecording();
      if (path != null) {
        await _saveIsoToGallery(path);
      } else {
        _toast('This phone couldn\'t finish the backup recording — it may not support recording while streaming.');
      }
    }
    if (mounted) setState(() {});
    _reportPhoneState();
  }

  Future<void> _saveIsoToGallery(String path) async {
    try {
      if (!await Gal.hasPermission(toAlbum: true)) await Gal.requestPermission(toAlbum: true);
      await Gal.putVideo(path, album: 'Church Cam');
      _toast('Backup recording saved to Gallery › Church Cam');
    } catch (e) {
      _toast('Couldn\'t save the recording to the gallery ($e).');
    }
  }

  String _isoElapsed() {
    final t = _camera.isoStartedAt;
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  // ── Director messages ───────────────────────────────────────────────────────
  void _showDirectorMessage(String text) {
    HapticFeedback.heavyImpact();
    Future.delayed(const Duration(milliseconds: 180), HapticFeedback.heavyImpact);
    setState(() => _directorMsg = text);
    _directorTimer?.cancel();
    _directorTimer = Timer(const Duration(seconds: 10), () { if (mounted) setState(() => _directorMsg = null); });
  }

  void _replyDirector(String text) {
    _conn?.sendDirectorReply(text);
    _directorTimer?.cancel();
    setState(() => _directorMsg = null);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  // ALWAYS LANDSCAPE: the app is locked to landscape, so the feed is always
  // horizontal. We report angle 0 to the desktop at all times → the studio
  // output stays horizontal, matching the phone's locked orientation.
  static const int _kForcedAngle = 0;

  Map<String, dynamic> _buildStateRestore() => {
        'capabilities': _camera.capabilities(),
        'orientationAngle': _kForcedAngle,
        'zoom': _camera.zoom,
        'filters': _filters.toJson(),
      };

  void _onCameraChanged() { if (mounted) setState(() {}); }

  void _onOrientation() {
    _conn?.sendOrientationAngle(_kForcedAngle);
    if (mounted) setState(() {});
  }

  // ── Desktop → mobile controls (Section 4) ────────────────────────────────────
  Future<void> _onRemoteCommand(RemoteCommand cmd) async {
    final conn = _conn;
    switch (cmd.action) {
      case 'rx_stats':
        // Desktop receive/decoder health → feed the ABR controller.
        final v = cmd.value;
        if (v is Map && _abr != null) {
          _abr!.updateRxStats(RxStats(
            decodeFps: (v['decodeFps'] as num?)?.toDouble() ?? 0,
            queueDepth: (v['queueDepth'] as num?)?.toInt() ?? 0,
            frameAgeMs: (v['frameAgeMs'] as num?)?.toDouble() ?? 0,
          ));
        }
        break;
      case 'set_zoom':
      case 'zoom':
        if (cmd.value is num) {
          final z = (cmd.value as num).toDouble();
          // Big jumps (preset buttons) glide like a zoom rocker; small steps
          // (a slider being dragged) apply directly so they track the hand.
          if ((z - _camera.zoom).abs() > 0.6) {
            _camera.animateZoomTo(z);
          } else {
            await _camera.setZoom(z);
          }
          conn?.confirmControl('zoom', z);
          _showZoomIndicator();
          _reportPhoneState();
        }
        break;
      case 'smart_zoom':
        // Desktop-driven Smart Zoom. Coordinates from the desktop are relative
        // to the PROGRAM picture it shows (already cropped), so they're mapped
        // back through the current crop on this side.
        if (cmd.value is Map) {
          final v = cmd.value as Map;
          final act = (v['action'] ?? '').toString();
          final zoom = (v['zoom'] as num?)?.toDouble();
          if (act == 'lock') {
            final x = (v['x'] as num?)?.toDouble() ?? 0.5;
            final y = (v['y'] as num?)?.toDouble() ?? 0.5;
            if (v['space'] == 'full') {
              _camera.smartLock(Offset(x, y), zoom: zoom);
            } else {
              _camera.smartLockProgram(Offset(x, y), zoom: zoom);
            }
            if (mounted) setState(() => _smartMode = true);
          } else if (act == 'release') {
            _camera.smartRelease();
          } else if (act == 'shot' && zoom != null) {
            _camera.smartSetShot(zoom);
          } else if (act == 'follow') {
            _camera.smartSetFollow(v['value'] == true);
          }
          conn?.confirmControl('smart_zoom', _camera.smartZoomState());
          _reportPhoneState();
        }
        break;
      case 'focus':
        if (cmd.value is Map) {
          final x = (cmd.value['x'] as num?)?.toDouble() ?? 0.5;
          final y = (cmd.value['y'] as num?)?.toDouble() ?? 0.5;
          final ok = await _camera.focusAt(x, y);
          _ringAt(Offset(x, y));
          conn?.confirmControl('focus', ok);
        }
        break;
      case 'exposure':
      case 'set_exposure':
        if (cmd.value is num) {
          final applied = await _camera.setExposure((cmd.value as num).toDouble());
          conn?.confirmControl('exposure', applied);
        }
        break;
      case 'focus_lock':
        {
          final lock = cmd.value == true || cmd.value == 'on' || cmd.value == 'lock';
          final ok = await _camera.setFocusLocked(lock);
          conn?.confirmControl('focus_lock', ok ? (lock ? 'locked' : 'auto') : 'unsupported');
        }
        break;
      case 'exposure_lock':
        {
          final lock = cmd.value == true || cmd.value == 'on' || cmd.value == 'lock';
          final ok = await _camera.setExposureLocked(lock);
          conn?.confirmControl('exposure_lock', ok ? (lock ? 'locked' : 'auto') : 'unsupported');
        }
        break;
      case 'white_balance':
      case 'set_white_balance':
        if (_camera.whiteBalanceSupported) {
          conn?.confirmControl('white_balance', cmd.value);
        } else {
          conn?.reportUnsupported('white_balance', 'not supported on this device');
        }
        break;
      case 'torch':
      case 'toggle_torch':
      case 'set_torch':
        {
          // set_torch carries an explicit on/off; torch/toggle_torch toggle.
          final v = cmd.value;
          final wantOn = v == true || v == 'on' || v == 1;
          final wantOff = v == false || v == 'off' || v == 0;
          if (wantOn && !_camera.torchOn) await _camera.toggleTorch();
          else if (wantOff && _camera.torchOn) await _camera.toggleTorch();
          else if (!wantOn && !wantOff) await _camera.toggleTorch(); // no explicit value → toggle
          conn?.confirmControl('torch', _camera.torchOn ? 'on' : 'off');
        }
        break;
      case 'flip':
      case 'switch_camera':
      case 'camera_flip':
        if (cmd.value == 'front') {
          await _camera.switchToPosition(CameraLensDirection.front);
        } else if (cmd.value == 'back') {
          await _camera.switchToPosition(CameraLensDirection.back);
        } else {
          await _camera.switchCamera();
        }
        conn?.sendCapabilities(_camera.capabilities());
        conn?.confirmControl('flip', _camera.lensDirection.name);
        break;
      case 'set_format':
      case 'format':
        // Desktop requests an encoder format/resolution. Map to setResolution.
        if (cmd.value is Map) {
          final w = (cmd.value['width'] as num?)?.toInt() ?? 1280;
          final h = (cmd.value['height'] as num?)?.toInt() ?? 720;
          final applied = await _camera.setResolution(w, h);
          conn?.confirmControl('format', applied);
        } else {
          conn?.reportUnsupported('set_format', 'expected {width,height}');
        }
        break;
      case 'resolution':
        if (cmd.value is Map) {
          final w = (cmd.value['width'] as num?)?.toInt() ?? 1280;
          final h = (cmd.value['height'] as num?)?.toInt() ?? 720;
          final applied = await _camera.setResolution(w, h);
          conn?.confirmControl('resolution', applied);
        }
        break;
      case 'filters':
      case 'filter_state':
        if (cmd.value is Map) {
          setState(() => _filters = CameraFilters.fromJson(cmd.value as Map));
          await saveFilters(_camera.lensDirection.name, _filters);
          conn?.confirmControl('filters', _filters.toJson());
        }
        break;
      // ── Saved shots, driven from the desktop ──
      case 'shot_recall':
        if (cmd.value is Map) {
          final id = (cmd.value as Map)['id']?.toString();
          final s = _shots.where((x) => x.id == id).firstOrNull;
          if (s != null) _recallShot(s);
        }
        break;
      case 'shot_save':
        if (cmd.value is Map) {
          final name = ((cmd.value as Map)['name'] ?? '').toString().trim();
          await _saveShot(name.isEmpty ? 'Shot ${_shots.length + 1}' : name);
        }
        break;
      case 'shot_delete':
        if (cmd.value is Map) await _deleteShot(((cmd.value as Map)['id'] ?? '').toString());
        break;
      // ── Director ──
      case 'director_msg':
        final text = cmd.value is Map ? ((cmd.value as Map)['text'] ?? '').toString() : (cmd.value ?? '').toString();
        if (text.trim().isNotEmpty) _showDirectorMessage(text.trim());
        break;
      case 'iso_record':
        await _setIso(cmd.value == true || (cmd.value is Map && (cmd.value as Map)['on'] == true));
        break;
      case 'audio_enable':
        await _setAudio(cmd.value == true || (cmd.value is Map && (cmd.value as Map)['on'] == true));
        break;
      case 'stabilize':
        await _setStabilize(cmd.value == true || (cmd.value is Map && (cmd.value as Map)['on'] == true));
        break;
      case 'desktop_state':
        // Informational (camera list, tally, transition) — ConnectionService
        // already stored it and the UI listens there. Not a command.
        break;
      default:
        // Log + report anything we don't handle so the desktop knows.
        debugPrint('[CameraScreen] unsupported command: ${cmd.action}');
        conn?.reportUnsupported(cmd.action, 'not implemented on mobile');
        break;
    }
  }

  // ── Local filter change → push to desktop + persist ──────────────────────────
  Future<void> _setFilters(CameraFilters f) async {
    setState(() => _filters = f);
    await saveFilters(_camera.lensDirection.name, f);
    _conn?.sendControl('filters', f.toJson());
  }

  // Local zoom is applied ON THE PHONE (hardware, or digital crop when the lens
  // has no zoom) — so it's already in the picture the desktop receives. It used
  // to also send 'set_zoom' to the desktop, which the desktop applied to its
  // USB webcam instead of this phone. Now we only REPORT the value.
  Future<void> _applyZoom(double z) async {
    await _camera.setZoom(z);
    // The framing no longer matches a saved shot.
    if (_activeShotId != null && mounted) setState(() => _activeShotId = null);
    _showZoomIndicator();
    _reportPhoneState();
  }

  void _animateZoom(double z) {
    if (_activeShotId != null) setState(() => _activeShotId = null);
    _camera.animateZoomTo(z);
    _showZoomIndicator();
    Future.delayed(const Duration(milliseconds: 700), _reportPhoneState);
  }

  void _showZoomIndicator() {
    if (!mounted) return;
    setState(() => _showZoomBar = true);
    _zoomBarTimer?.cancel();
    _zoomBarTimer = Timer(const Duration(seconds: 2), () { if (mounted) setState(() => _showZoomBar = false); });
  }

  // ── Smart Zoom (phone side) ──────────────────────────────────────────────────
  /// Where the camera frame actually sits on screen (preview is cover-fitted,
  /// so part of it is cropped off the screen edges).
  Rect _frameRectOnScreen(Size size) {
    final controller = _camera.controller;
    if (controller == null) return Offset.zero & size;
    final ar = controller.value.aspectRatio;
    final landscapeAr = ar > 1 ? ar : (1 / ar);
    final fw = landscapeAr * 1000, fh = 1000.0;
    final s = math.max(size.width / fw, size.height / fh);
    final dw = fw * s, dh = fh * s;
    return Rect.fromLTWH((size.width - dw) / 2, (size.height - dh) / 2, dw, dh);
  }

  Offset _screenToFrame(Offset p, Size size) {
    final r = _frameRectOnScreen(size);
    return Offset(((p.dx - r.left) / r.width).clamp(0.0, 1.0), ((p.dy - r.top) / r.height).clamp(0.0, 1.0));
  }

  void _toggleSmartMode() {
    setState(() => _smartMode = !_smartMode);
    if (!_smartMode && _camera.smartZoomActive) _camera.smartRelease();
  }

  void _smartTap(TapDownDetails d, Size size) {
    final p = _screenToFrame(d.localPosition, size);
    _camera.smartLock(p);
    // Focus + expose on the person too — they're the subject now.
    _camera.focusAt(p.dx, p.dy);
    _ringAt(Offset(d.localPosition.dx / size.width, d.localPosition.dy / size.height));
  }

  void _ringAt(Offset normalized) {
    setState(() => _focusPoint = normalized);
    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(milliseconds: 900), () { if (mounted) setState(() => _focusPoint = null); });
  }

  Future<void> _tapFocus(TapDownDetails d, Size size) async {
    final nx = (d.localPosition.dx / size.width).clamp(0.0, 1.0);
    final ny = (d.localPosition.dy / size.height).clamp(0.0, 1.0);
    await _camera.focusAt(nx, ny);
    _ringAt(Offset(nx, ny));
    _conn?.sendControl('focus', {'x': nx, 'y': ny});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _camera.stopStreaming();
    } else if (state == AppLifecycleState.resumed) {
      if (_camera.isInitialized) _camera.startStreaming();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _adaptiveTimer?.cancel();
    _statusTimer?.cancel();
    _focusTimer?.cancel();
    _zoomBarTimer?.cancel();
    _stateReportTimer?.cancel();
    _camera.onSmartZoomChanged = null;
    _camera.onAids = null;
    _camera.onIsoFinished = null;
    _directorTimer?.cancel();
    _isoTicker?.cancel();
    _stopLevel();
    _audio.removeListener(_onAudioLevel);
    _audio.dispose();
    _aidsImage.value?.dispose();
    _aidsImage.dispose();
    _tilt.dispose();
    // A recording in progress must not be lost when the screen closes.
    if (_camera.isoRecording) {
      _camera.stopIsoRecording().then((p) { if (p != null) Gal.putVideo(p, album: 'Church Cam').catchError((_) {}); });
    }
    _deviceStatus.dispose();
    _abr?.dispose();
    _conn?.removeCommandListener(_onRemoteCommand);
    _conn?.stateProvider = null;
    _conn?.onVideoReady = null;
    _orientation.removeListener(_onOrientation);
    _orientation.dispose();
    _camera.removeListener(_onCameraChanged);
    _camera.dispose();
    super.dispose();
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  UI
  //  Landscape broadcast-camera layout:
  //    • full-bleed viewfinder (pinch anywhere to zoom, tap to focus / pick)
  //    • left icon rail = tabs (Live · Smart · Image · Studio · Settings);
  //      a tab slides a panel in beside it, the picture stays live
  //    • top HUD: link, Wi-Fi, battery · tally · format
  //    • right tool rail: lens, torch, AF lock, AE lock, Smart
  //    • bottom zoom dial: presets + drag-to-scrub
  // ══════════════════════════════════════════════════════════════════════════
  static const double _railW = 72;

  double _panelW(Size size) => math.min(380.0, math.max(300.0, size.width * 0.38));

  void _openTab(_Tab t) {
    setState(() => _tab = _tab == t ? null : t);
  }

  @override
  Widget build(BuildContext context) {
    if (_permissionDenied) return _permissionDeniedView();
    if (_initError != null) return _errorView(_initError!);
    if (_initializing || !_camera.isInitialized) return _startingView();

    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      final panelW = _panelW(size);
      final panelOpen = _tab != null;
      final contentLeft = _railW + (panelOpen ? panelW : 0);

      return Stack(
        fit: StackFit.expand,
        children: [
          // ── Viewfinder ─────────────────────────────────────────────────────
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: (_) => _baseZoom = _camera.zoom,
            onScaleUpdate: (d) {
              if (d.pointerCount >= 2 && (d.scale - 1.0).abs() > 0.01) {
                _applyZoom(_baseZoom * d.scale);
              } else if (d.pointerCount == 1 && _camera.canPan && !panelOpen) {
                // One finger on a zoomed picture = move the frame, like
                // dragging a photo. Shot no longer matches a saved one.
                final fr = _frameRectOnScreen(size);
                _camera.panBy(d.focalPointDelta.dx / fr.width, d.focalPointDelta.dy / fr.height);
                if (_activeShotId != null) setState(() => _activeShotId = null);
              }
            },
            onScaleEnd: (_) => _reportPhoneState(),
            onTapDown: (d) {
              if (panelOpen) { setState(() => _tab = null); return; }
              _smartMode ? _smartTap(d, size) : _tapFocus(d, size);
            },
            child: FilteredPreview(filters: _filters, child: _buildPreview()),
          ),

          IgnorePointer(
            child: CustomPaint(
              size: size,
              painter: _FramingPainter(
                camera: _camera,
                frameRect: _frameRectOnScreen(size),
                showFrame: _smartMode || !_camera.framer.isIdentity,
              ),
            ),
          ),

          // Zebra / focus peaking (viewfinder only — never in the stream).
          if (_settings.zebraOn || _settings.peakingOn)
            IgnorePointer(
              child: ValueListenableBuilder<ui.Image?>(
                valueListenable: _aidsImage,
                builder: (_, img, __) => img == null
                    ? const SizedBox.shrink()
                    : CustomPaint(size: size, painter: _AidsPainter(
                        image: img,
                        frameRect: _frameRectOnScreen(size),
                        rotation: _camera.outRotation,
                        mirror: _camera.lensDirection == CameraLensDirection.front,
                      )),
              ),
            ),

          // Rule-of-thirds grid + horizon level.
          if (_settings.gridOn)
            IgnorePointer(child: CustomPaint(size: size, painter: _GridPainter(_camera, _frameRectOnScreen(size)))),
          if (_settings.levelOn)
            IgnorePointer(
              child: ValueListenableBuilder<double>(
                valueListenable: _tilt,
                builder: (_, t, __) => CustomPaint(size: size, painter: _LevelPainter(t)),
              ),
            ),

          if (_focusPoint != null)
            Positioned(
              left: _focusPoint!.dx * size.width - 36,
              top: _focusPoint!.dy * size.height - 36,
              child: const IgnorePointer(child: _FocusRing()),
            ),

          // ON AIR rim
          Consumer<ConnectionService>(
            builder: (_, conn, __) => IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                // Red = on air; green = the director has cued this camera next.
                decoration: BoxDecoration(
                  border: Border.all(
                    color: conn.isSelfLive ? C.tally : (conn.isSelfCued ? C.ok : Colors.transparent),
                    width: 3,
                  ),
                ),
              ),
            ),
          ),

          // Top scrim so the HUD reads on bright scenes.
          const Positioned(
            left: 0, right: 0, top: 0, height: 88,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [Color(0x8C000000), Color(0x00000000)],
                  ),
                ),
              ),
            ),
          ),

          // ── Top HUD ────────────────────────────────────────────────────────
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic,
            left: contentLeft + S.md, right: S.md, top: S.md,
            child: _buildHud(),
          ),

          if (_showMetrics)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic,
              left: contentLeft + S.md, top: 56,
              child: MetricsOverlay(camera: _camera, status: _deviceStatus),
            ),

          // Reading text pushed from the desktop, under the tally.
          Consumer<ConnectionService>(
            builder: (_, conn, __) => conn.readingText.trim().isEmpty
                ? const SizedBox.shrink()
                : Positioned(
                    top: 56, left: contentLeft + 80, right: 96,
                    child: IgnorePointer(child: Center(child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(R.md)),
                      child: Text(conn.readingText, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: C.text, fontSize: 17, fontWeight: FontWeight.w700, height: 1.3)),
                    ))),
                  ),
          ),

          // Director's message — big, unmissable, with one-tap replies.
          if (_directorMsg != null)
            Positioned(
              top: 56, left: contentLeft + S.md, right: 84,
              child: Center(child: _buildDirectorBanner(_directorMsg!)),
            ),

          if (_smartMode && !_camera.smartZoomActive)
            Positioned(
              left: contentLeft + S.md, right: 84, bottom: 84,
              child: IgnorePointer(child: Center(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(color: const Color(0xD9000000), borderRadius: BorderRadius.circular(R.pill), border: Border.all(color: C.accent)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  PhosphorIcon(PhosphorIconsFill.handTap, color: C.accent, size: 18),
                  const SizedBox(width: 8),
                  const Flexible(child: Text('اضغط على الشخص لمتابعته  ·  Tap a person to follow',
                      style: T.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
              ))),
            ),

          // ── Right tool rail ────────────────────────────────────────────────
          // Scrolls rather than overflowing on short (landscape) screens.
          Positioned(right: S.md, top: 56, bottom: S.md, child: Center(child: SingleChildScrollView(child: _buildToolRail()))),

          // ── Bottom zoom dial ───────────────────────────────────────────────
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic,
            left: contentLeft, right: 76, bottom: S.md,
            child: Center(child: _buildZoomDial()),
          ),

          // Big transient zoom readout while pinching / scrubbing.
          if (_showZoomBar)
            Positioned(
              left: contentLeft, right: 0, top: 0, bottom: 0,
              child: IgnorePointer(child: Center(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(R.lg)),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('${_camera.zoom.toStringAsFixed(1)}×', style: T.zoom.copyWith(fontSize: 34)),
                  if (!_camera.hasHardwareZoom) const Text('DIGITAL', style: T.overline),
                ]),
              ))),
            ),

          // ── Side panel (tab content) ───────────────────────────────────────
          AnimatedPositioned(
            duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic,
            left: panelOpen ? _railW : _railW - panelW - 8,
            top: 0, bottom: 0, width: panelW,
            child: _buildPanel(),
          ),

          // ── Left tab rail ──────────────────────────────────────────────────
          Positioned(left: 0, top: 0, bottom: 0, width: _railW, child: _buildRail()),
        ],
      );
    });
  }

  Widget _buildPreview() {
    final controller = _camera.controller!;
    // Landscape-locked: fill the whole screen with the camera feed. The camera
    // reports its aspect ratio in the sensor's natural (portrait) orientation, so
    // in landscape we use its INVERSE. BoxFit.cover crops to fill without bars.
    final ar = controller.value.aspectRatio;
    final landscapeAr = ar > 1 ? ar : (1 / ar); // ensure ≥1 (wide) for landscape
    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: landscapeAr * 1000,
            height: 1000,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }

  // ── Left rail (tabs) ────────────────────────────────────────────────────────
  Widget _buildRail() {
    Widget tab(_Tab t, IconData icon, IconData activeIcon, String label) {
      final on = _tab == t;
      return Semantics(
        button: true, selected: on, label: label,
        child: Tooltip(
          message: label,
          preferBelow: false,
          child: GestureDetector(
            onTap: () { HapticFeedback.selectionClick(); _openTab(t); },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 48, height: 48, // 6 tabs must fit a ~400dp landscape height
              margin: const EdgeInsets.symmetric(vertical: 2),
              decoration: BoxDecoration(
                color: on ? C.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(R.md),
              ),
              child: PhosphorIcon(on ? activeIcon : icon, size: 24, color: on ? C.accentInk : C.textDim),
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xF00D0D12),
        border: Border(right: BorderSide(color: C.hairline)),
      ),
      child: SafeArea(
        right: false,
        child: Column(children: [
          const SizedBox(height: S.md),
          // Viewfinder "home": closes any panel.
          Semantics(
            button: true, label: 'Viewfinder',
            child: GestureDetector(
              onTap: () => setState(() => _tab = null),
              child: Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(R.md),
                  border: Border.all(color: _tab == null ? C.accent : C.border, width: 1.5),
                ),
                child: PhosphorIcon(PhosphorIconsFill.aperture, color: _tab == null ? C.accent : C.textDim, size: 24),
              ),
            ),
          ),
          const SizedBox(height: S.md),
          Container(width: 28, height: 1, color: C.border),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: S.sm),
              child: Column(children: [
                tab(_Tab.live, PhosphorIconsRegular.broadcast, PhosphorIconsFill.broadcast, 'Live cameras'),
                tab(_Tab.shots, PhosphorIconsRegular.bookmarksSimple, PhosphorIconsFill.bookmarksSimple, 'Saved shots'),
                tab(_Tab.smart, PhosphorIconsRegular.userFocus, PhosphorIconsFill.userFocus, 'Smart Zoom'),
                tab(_Tab.image, PhosphorIconsRegular.faders, PhosphorIconsFill.faders, 'Image & filters'),
                tab(_Tab.studio, PhosphorIconsRegular.projectorScreen, PhosphorIconsFill.projectorScreen, 'Studio control'),
              ]),
            ),
          ),
          tab(_Tab.settings, PhosphorIconsRegular.gearSix, PhosphorIconsFill.gearSix, 'Settings'),
          const SizedBox(height: S.md),
        ]),
      ),
    );
  }

  // ── Top HUD ─────────────────────────────────────────────────────────────────
  Widget _buildHud() {
    return Consumer<ConnectionService>(builder: (_, conn, __) {
      final connected = conn.status == ConnectionStatus.connected;
      final ms = conn.latencyMs;
      final linkColor = !connected ? C.tally : (ms < 60 ? C.ok : (ms <= 150 ? C.warn : C.tally));
      final linkText = connected ? '$ms ms' : (conn.status == ConnectionStatus.reconnecting ? 'Reconnecting' : 'Offline');

      final bars = _deviceStatus.wifiBars;
      final wifiIcon = _deviceStatus.wifiRssi <= -127 ? PhosphorIconsRegular.wifiSlash
          : bars >= 3 ? PhosphorIconsBold.wifiHigh
          : bars == 2 ? PhosphorIconsBold.wifiMedium
          : bars == 1 ? PhosphorIconsBold.wifiLow : PhosphorIconsBold.wifiNone;
      final bp = _deviceStatus.batteryPercent;
      final batIcon = _deviceStatus.charging ? PhosphorIconsBold.batteryCharging
          : bp < 0 ? PhosphorIconsBold.batteryMedium
          : bp > 80 ? PhosphorIconsBold.batteryFull
          : bp > 50 ? PhosphorIconsBold.batteryHigh
          : bp > 20 ? PhosphorIconsBold.batteryMedium
          : bp > 10 ? PhosphorIconsBold.batteryLow : PhosphorIconsBold.batteryWarning;
      final batColor = _deviceStatus.charging ? C.ok : (bp >= 0 && bp <= 15 ? C.tally : (bp >= 0 && bp <= 30 ? C.warn : C.text));

      final live = conn.isSelfLive;
      final cued = conn.isSelfCued;
      final tallyColor = live ? C.tally : (cued ? C.ok : null);
      final lost = _camera.smartZoomActive && _camera.tracker.lost;

      return Row(children: [
        // Left side: status chips. Clipped to their share of the bar so extra
        // chips (mic, REC) can never push the tally off screen.
        Expanded(child: ClipRect(child: SingleChildScrollView(
          scrollDirection: Axis.horizontal, physics: const NeverScrollableScrollPhysics(),
          child: Row(children: [
        GestureDetector(
          onTap: () => setState(() => _showMetrics = !_showMetrics),
          child: Semantics(
            button: true, label: 'Connection $linkText. Tap for stream stats',
            child: HudChip(
              borderColor: linkColor.withValues(alpha: 0.6),
              child: Row(children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: linkColor, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text(linkText, style: T.hud.copyWith(color: linkColor)),
              ]),
            ),
          ),
        ),
        const SizedBox(width: S.sm),
        HudChip(child: Row(children: [
          PhosphorIcon(wifiIcon, size: 16, color: C.text),
          const SizedBox(width: 8),
          PhosphorIcon(batIcon, size: 18, color: batColor),
          if (bp >= 0) ...[const SizedBox(width: 4), Text('$bp%', style: T.hud.copyWith(color: batColor))],
        ])),
        // Live microphone meter while the phone's audio is sent.
        if (_audio.running) ...[
          const SizedBox(width: S.sm),
          AnimatedBuilder(
            animation: _audio,
            builder: (_, __) => HudChip(child: Row(children: [
              PhosphorIcon(PhosphorIconsFill.microphone, size: 15, color: C.ok),
              const SizedBox(width: 6),
              _MiniMeter(level: _audio.level),
            ])),
          ),
        ],
        // Backup recording on the phone.
        if (_camera.isoRecording) ...[
          const SizedBox(width: S.sm),
          HudChip(
            borderColor: C.tally,
            child: Row(children: [
              Container(width: 8, height: 8, decoration: const BoxDecoration(color: C.tally, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text('REC ${_isoElapsed()}', style: T.hud.copyWith(color: C.tally)),
            ]),
          ),
        ],
        ])))),
        const SizedBox(width: S.sm),
        // Tally — the one thing an operator must read from across the room.
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: tallyColor ?? C.scrim,
            borderRadius: BorderRadius.circular(R.sm),
            border: Border.all(color: tallyColor ?? C.hairline),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            PhosphorIcon(tallyColor != null ? PhosphorIconsFill.record : PhosphorIconsRegular.record, size: 14,
                color: live ? Colors.white : (cued ? C.accentInk : C.textDim)),
            const SizedBox(width: 6),
            Text(live ? 'ON AIR' : (cued ? 'NEXT' : 'STANDBY'),
                style: T.hud.copyWith(color: live ? Colors.white : (cued ? C.accentInk : C.textDim), letterSpacing: 1.4, fontWeight: FontWeight.w900)),
          ]),
        ),
        if (lost) ...[
          const SizedBox(width: S.sm),
          HudChip(
            borderColor: C.warn,
            child: Row(children: [
              PhosphorIcon(PhosphorIconsFill.warningCircle, size: 16, color: C.warn),
              const SizedBox(width: 6),
              Text('Subject lost', style: T.hud.copyWith(color: C.warn)),
            ]),
          ),
        ],
        const SizedBox(width: S.sm),
        // Right side: secondary info, right-aligned and clipped (never overflows).
        Expanded(child: ClipRect(child: SingleChildScrollView(
          scrollDirection: Axis.horizontal, reverse: true, physics: const NeverScrollableScrollPhysics(),
          child: Row(children: [
        // Secondary info — dropped while a panel narrows the viewfinder, so the
        // link, battery and tally never get pushed off screen.
        if (_tab == null) ...[
          HudChip(child: Text(
            '${_camera.measuredFps > 0 ? _camera.measuredFps : _camera.targetFps} FPS  ·  ${_camera.isH264Mode ? 'H.264' : 'MJPEG'}',
            style: T.hud.copyWith(color: C.textDim),
          )),
          const SizedBox(width: 64), // keep clear of the tool rail column
        ],
        ])))),
      ]);
    });
  }

  // ── Right tool rail ─────────────────────────────────────────────────────────
  Widget _buildToolRail() {
    Widget lockBadge() => Container(
          width: 18, height: 18,
          decoration: BoxDecoration(color: C.bg, shape: BoxShape.circle, border: Border.all(color: C.warn, width: 1.5)),
          child: PhosphorIcon(PhosphorIconsFill.lockSimple, size: 10, color: C.warn),
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      ToolButton(
        icon: PhosphorIconsRegular.userFocus, activeIcon: PhosphorIconsFill.userFocus,
        label: _smartMode ? 'Smart Zoom on' : 'Smart Zoom',
        active: _smartMode, onTap: _toggleSmartMode,
      ),
      const SizedBox(height: S.sm),
      ToolButton(
        icon: PhosphorIconsRegular.crosshair, activeIcon: PhosphorIconsBold.crosshair,
        label: _camera.focusLocked ? 'Focus locked' : 'Lock focus',
        active: _camera.focusLocked, activeColor: C.warn,
        badge: _camera.focusLocked ? lockBadge() : null,
        onTap: () => _camera.setFocusLocked(!_camera.focusLocked),
      ),
      const SizedBox(height: S.sm),
      ToolButton(
        icon: PhosphorIconsRegular.sun, activeIcon: PhosphorIconsFill.sun,
        label: _camera.exposureLocked ? 'Exposure locked' : 'Lock exposure',
        active: _camera.exposureLocked, activeColor: C.warn,
        badge: _camera.exposureLocked ? lockBadge() : null,
        onTap: () => _camera.setExposureLocked(!_camera.exposureLocked),
      ),
      const SizedBox(height: S.sm),
      ToolButton(
        icon: PhosphorIconsRegular.lightningSlash, activeIcon: PhosphorIconsFill.lightning,
        label: _camera.torchOn ? 'Torch on' : 'Torch',
        active: _camera.torchOn, activeColor: C.warn,
        onTap: _camera.hasTorch ? () => _camera.toggleTorch() : null,
      ),
      const SizedBox(height: S.sm),
      ToolButton(
        icon: PhosphorIconsRegular.cameraRotate,
        label: 'Switch lens',
        onTap: () async {
          await _camera.switchCamera();
          if (mounted) setState(() => _smartMode = false);
          _conn?.sendCapabilities(_camera.capabilities());
          _reportPhoneState();
        },
      ),
    ]);
  }

  // ── Zoom dial ───────────────────────────────────────────────────────────────
  // Presets for one-tap framing, the live value in the middle, and the whole
  // pill doubles as a scrubber: drag sideways to zoom smoothly.
  Widget _buildZoomDial() {
    final zMin = _camera.minZoom;
    final zMax = _camera.maxZoom > zMin ? _camera.maxZoom : zMin + 1;
    final presets = <double>[1, 2, 3, 5].where((z) => z >= zMin - 0.01 && z <= zMax + 0.01).toList();
    final z = _camera.zoom;

    Widget preset(double p) {
      final on = (z - p).abs() < 0.05;
      return Semantics(
        button: true, selected: on, label: 'Zoom ${p.toStringAsFixed(0)} times',
        child: GestureDetector(
          onTap: () { HapticFeedback.selectionClick(); _animateZoom(p); },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 44, height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: on ? C.text : Colors.transparent, shape: BoxShape.circle),
            child: Text('${p.toStringAsFixed(0)}×', style: T.hud.copyWith(color: on ? C.accentInk : C.text, fontSize: 13)),
          ),
        ),
      );
    }

    return GestureDetector(
      onHorizontalDragStart: (_) => _baseZoom = _camera.zoom,
      onHorizontalDragUpdate: (d) {
        // ~260dp of drag sweeps the full range.
        _baseZoom = (_baseZoom + d.delta.dx * (zMax - zMin) / 260).clamp(zMin, zMax);
        _applyZoom(_baseZoom);
      },
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: const Color(0xB3000000),
          borderRadius: BorderRadius.circular(R.pill),
          border: Border.all(color: C.hairline),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _dialIcon(PhosphorIconsBold.minus, 'Zoom out', () => _applyZoom(z - (zMax - zMin) / 10)),
          ...presets.map(preset),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: C.accentSoft, borderRadius: BorderRadius.circular(R.pill)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              PhosphorIcon(PhosphorIconsBold.magnifyingGlass, size: 14, color: C.accent),
              const SizedBox(width: 6),
              Text('${z.toStringAsFixed(1)}×', style: T.zoom.copyWith(color: C.accent)),
            ]),
          ),
          _dialIcon(PhosphorIconsBold.plus, 'Zoom in', () => _applyZoom(z + (zMax - zMin) / 10)),
        ]),
      ),
    );
  }

  Widget _dialIcon(IconData icon, String label, VoidCallback onTap) => Semantics(
        button: true, label: label,
        child: GestureDetector(
          onTap: () { HapticFeedback.selectionClick(); onTap(); },
          child: SizedBox(width: 44, height: 44, child: PhosphorIcon(icon, size: 18, color: C.text)),
        ),
      );

  // ── Side panel ──────────────────────────────────────────────────────────────
  Widget _buildPanel() {
    final t = _tab;
    late final IconData icon;
    late final String title;
    Widget body = const SizedBox.shrink();
    switch (t) {
      case _Tab.live:
        icon = PhosphorIconsFill.broadcast; title = 'Live cameras'; body = _livePanel();
      case _Tab.shots:
        icon = PhosphorIconsFill.bookmarksSimple; title = 'Saved shots'; body = _shotsPanel();
      case _Tab.smart:
        icon = PhosphorIconsFill.userFocus; title = 'Smart Zoom'; body = _smartPanel();
      case _Tab.image:
        icon = PhosphorIconsFill.faders; title = 'Image'; body = _imagePanel();
      case _Tab.studio:
        icon = PhosphorIconsFill.projectorScreen; title = 'Studio';
        body = StudioPanel(
          audioOn: _audio.running,
          audioLevel: _audio.level,
          onAudioChanged: (v) => _setAudio(v),
          isoRecording: _camera.isoRecording,
          isoElapsed: _isoElapsed(),
          onIsoChanged: (v) => _setIso(v),
        );
      case _Tab.settings:
        icon = PhosphorIconsFill.gearSix; title = 'Settings';
        body = SettingsPanel(onDisconnect: _disconnect, onSettingsChanged: (s) => setState(() => _settings = s));
      case null:
        icon = PhosphorIconsFill.aperture; title = '';
    }
    return Material(
      color: C.surface,
      child: Container(
        decoration: const BoxDecoration(border: Border(right: BorderSide(color: C.hairline))),
        child: SafeArea(
          left: false,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(S.lg, S.md, S.sm, S.sm),
              child: Row(children: [
                PhosphorIcon(icon, size: 20, color: C.accent),
                const SizedBox(width: S.sm),
                Expanded(child: Text(title, style: T.title)),
                Semantics(
                  button: true, label: 'Close panel',
                  child: IconButton(
                    onPressed: () => setState(() => _tab = null),
                    icon: PhosphorIcon(PhosphorIconsBold.x, size: 18, color: C.textDim),
                  ),
                ),
              ]),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: ValueKey(t), // each tab opens at its top
                padding: const EdgeInsets.fromLTRB(S.lg, S.sm, S.lg, S.lg),
                child: body,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // Live: every camera the desktop can put on air (incl. this phone) + the cut.
  Widget _livePanel() {
    return Consumer<ConnectionService>(builder: (_, conn, __) {
      final cams = conn.desktopCameras;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PanelSection(
          title: 'Put on air',
          children: [
            if (cams.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: S.md),
                child: Text('Waiting for the desktop to list its cameras…', style: T.body),
              )
            else
              ...cams.map((c) {
                final live = conn.activeCameraId == c.id;
                final self = c.id == conn.selfCameraId;
                final icon = c.kind == 'ip' ? PhosphorIconsRegular.videoCamera
                    : (c.kind == 'mobile' || c.kind == 'webrtc') ? PhosphorIconsRegular.deviceMobileCamera
                    : PhosphorIconsRegular.webcam;
                return PanelTile(
                  icon: icon,
                  title: self ? 'This phone' : c.label,
                  subtitle: self ? c.label : _kindLabel(c.kind),
                  highlighted: live,
                  highlightColor: C.tally,
                  trailing: live
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: C.tally, borderRadius: BorderRadius.circular(R.sm)),
                          child: const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1)),
                        )
                      : PhosphorIcon(PhosphorIconsBold.caretRight, size: 16, color: C.textFaint),
                  onTap: live ? null : () => conn.selectDesktopCamera(c.id),
                );
              }),
          ],
        ),
        if (conn.transitions.isNotEmpty)
          PanelSection(
            title: 'Transition',
            children: [
              Wrap(spacing: S.sm, runSpacing: S.sm, children: conn.transitions.map((t) => Choice(
                    label: t.labelAr.isNotEmpty ? t.labelAr : t.label,
                    selected: conn.switchTransition == t.id,
                    onTap: () => conn.setSwitchTransition(t.id),
                  )).toList()),
            ],
          ),
      ]);
    });
  }

  // Saved shots: one tap to glide to a framing; long-press to manage.
  Widget _shotsPanel() {
    String sub(ShotPreset s) {
      final parts = <String>[];
      if (s.hwZoom > 1.01) parts.add('${s.hwZoom.toStringAsFixed(1)}× lens');
      if (s.crop > 1.01) parts.add('${s.crop.toStringAsFixed(1)}× frame');
      return parts.isEmpty ? 'Full picture' : parts.join(' · ');
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: double.infinity,
        height: 52,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md))),
          onPressed: _promptSaveShot,
          icon: PhosphorIcon(PhosphorIconsBold.bookmarkSimple, size: 18, color: C.accentInk),
          label: const Text('Save current framing', style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      ),
      const SizedBox(height: S.sm),
      const Text('Zoom, then drag the picture with one finger to frame it. Save it, and recall it any time with one tap — from here or from the desktop.', style: T.body),
      const SizedBox(height: S.lg),
      if (_shots.isEmpty)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(S.lg),
          decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(R.md), border: Border.all(color: C.border)),
          child: Column(children: [
            PhosphorIcon(PhosphorIconsRegular.bookmarksSimple, size: 28, color: C.textFaint),
            const SizedBox(height: S.sm),
            const Text('No saved shots yet', style: T.label),
            const SizedBox(height: 2),
            const Text('e.g. Altar, Pulpit, Choir, Wide', style: T.caption),
          ]),
        )
      else
        PanelSection(
          title: 'Shots  (${_shots.length})',
          children: _shots.map((s) => GestureDetector(
                onLongPress: () => _shotMenu(s),
                child: PanelTile(
                  icon: PhosphorIconsRegular.frameCorners,
                  title: s.name,
                  subtitle: sub(s),
                  highlighted: _activeShotId == s.id,
                  trailing: _activeShotId == s.id
                      ? PhosphorIcon(PhosphorIconsFill.checkCircle, size: 20, color: C.accent)
                      : PhosphorIcon(PhosphorIconsBold.play, size: 16, color: C.textFaint),
                  onTap: () => _recallShot(s),
                ),
              )).toList(),
        ),
      if (_shots.isNotEmpty) const Text('Long-press a shot to rename, update or delete it.', style: T.caption),
    ]);
  }

  Future<void> _promptSaveShot({ShotPreset? replace}) async {
    final ctrl = TextEditingController(text: replace?.name ?? '');
    const suggestions = ['المذبح', 'المنبر', 'الخورس', 'الشعب', 'لقطة واسعة'];
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(replace == null ? 'Save shot' : 'Rename shot', style: T.title),
        content: SingleChildScrollView(child: SizedBox(width: 360, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: ctrl, autofocus: true, style: const TextStyle(color: C.text), decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: S.md),
          Wrap(spacing: S.sm, runSpacing: S.sm, children: suggestions.map((n) => Choice(
                label: n, selected: false, onTap: () => Navigator.pop(ctx, n),
              )).toList()),
        ]))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name == null) return;
    final n = name.isEmpty ? 'Shot ${_shots.length + 1}' : name;
    if (replace != null) {
      await _renameShot(replace.id, n);
    } else {
      await _saveShot(n);
      _toast('Saved "$n"');
    }
  }

  void _shotMenu(ShotPreset s) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: C.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: PhosphorIcon(PhosphorIconsRegular.pencilSimple, color: C.text),
          title: const Text('Rename'),
          onTap: () { Navigator.pop(ctx); _promptSaveShot(replace: s); },
        ),
        ListTile(
          leading: PhosphorIcon(PhosphorIconsRegular.arrowsClockwise, color: C.text),
          title: const Text('Update to current framing'),
          onTap: () { Navigator.pop(ctx); _saveShot(s.name, replaceId: s.id); _toast('Updated "${s.name}"'); },
        ),
        ListTile(
          leading: PhosphorIcon(PhosphorIconsRegular.trash, color: C.tally),
          title: const Text('Delete', style: TextStyle(color: C.tally)),
          onTap: () { Navigator.pop(ctx); _deleteShot(s.id); },
        ),
      ])),
    );
  }

  Widget _buildDirectorBanner(String text) => Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 560),
          padding: const EdgeInsets.fromLTRB(S.lg, S.md, S.sm, S.md),
          decoration: BoxDecoration(
            color: const Color(0xF0151518),
            borderRadius: BorderRadius.circular(R.lg),
            border: Border.all(color: C.warn, width: 2),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              PhosphorIcon(PhosphorIconsFill.megaphone, size: 18, color: C.warn),
              const SizedBox(width: S.sm),
              Text('DIRECTOR', style: T.overline.copyWith(color: C.warn)),
              const Spacer(),
              Semantics(
                button: true, label: 'Dismiss',
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _directorMsg = null),
                  icon: PhosphorIcon(PhosphorIconsBold.x, size: 16, color: C.textDim),
                ),
              ),
            ]),
            Text(text, style: const TextStyle(color: C.text, fontSize: 22, fontWeight: FontWeight.w800, height: 1.25)),
            const SizedBox(height: S.md),
            Wrap(spacing: S.sm, children: [
              Choice(label: 'تمام', icon: PhosphorIconsBold.check, selected: true, selectedColor: C.ok, onTap: () => _replyDirector('تمام 👍')),
              Choice(label: 'ثواني', icon: PhosphorIconsBold.hourglassMedium, selected: false, onTap: () => _replyDirector('ثواني ✋')),
            ]),
          ]),
        ),
      );

  String _kindLabel(String kind) => switch (kind) {
        'ip' => 'IP camera',
        'mobile' => 'Phone',
        'webrtc' => 'Phone (WebRTC)',
        _ => 'USB camera',
      };

  // Smart Zoom: arm, shot size, follow, release.
  Widget _smartPanel() {
    final f = _camera.framer;
    final active = _camera.smartZoomActive;
    final lost = active && _camera.tracker.lost;
    final statusColor = lost ? C.warn : (active ? C.ok : C.textFaint);
    final statusText = !_smartMode ? 'Off' : !active ? 'Tap a person on screen' : lost ? 'Subject lost — tap them again' : (f.follow ? 'Following' : 'Locked');
    const shots = [
      ('Wide', ShotSize.wide, PhosphorIconsRegular.usersThree),
      ('Medium', ShotSize.medium, PhosphorIconsRegular.user),
      ('Close', ShotSize.close, PhosphorIconsRegular.userFocus),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PanelTile(
        icon: PhosphorIconsFill.userFocus,
        title: 'Smart Zoom',
        subtitle: statusText,
        highlighted: _smartMode,
        trailing: Switch(value: _smartMode, onChanged: (_) => _toggleSmartMode()),
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: S.xl, top: S.xs),
        child: Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle)),
          const SizedBox(width: S.sm),
          const Expanded(child: Text('Frames and follows one person with smooth, operator-style moves.', style: T.body)),
        ]),
      ),
      PanelSection(
        title: 'Shot size',
        children: [
          Wrap(spacing: S.sm, runSpacing: S.sm, children: shots.map((s) => Choice(
                label: s.$1, icon: s.$3,
                selected: (f.shotZoom - s.$2).abs() < 0.01,
                onTap: () { _camera.smartSetShot(s.$2); setState(() {}); },
              )).toList()),
        ],
      ),
      PanelSection(
        title: 'Behaviour',
        children: [
          PanelTile(
            icon: PhosphorIconsRegular.personSimpleWalk,
            title: 'Follow movement',
            subtitle: f.follow ? 'Keeps the person framed as they move' : 'Holds the shot where you locked it',
            trailing: Switch(value: f.follow, onChanged: (v) { _camera.smartSetFollow(v); setState(() {}); }),
          ),
          PanelTile(
            icon: PhosphorIconsRegular.arrowsOutSimple,
            title: 'Release',
            subtitle: 'Glide back to the full picture',
            onTap: active ? () { _camera.smartRelease(); setState(() {}); } : null,
          ),
        ],
      ),
    ]);
  }

  // Image: looks + manual grading (applied to this phone's feed on the desktop).
  Widget _imagePanel() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PanelSection(
        title: 'Looks',
        children: [
          // 'Reset' is a duplicate of 'Natural' in the preset list — the Adjust
          // section has its own Reset, so it's left out here.
          Wrap(spacing: S.sm, runSpacing: S.sm, children: kFilterPresets.where((p) => p.name != 'Reset').map((p) => Choice(
                label: p.name,
                selected: _filters.toJson().toString() == p.filters.toJson().toString(),
                onTap: () => _setFilters(p.filters),
              )).toList()),
        ],
      ),
      PanelSection(
        title: 'Adjust',
        trailing: TextButton.icon(
          onPressed: () => _setFilters(CameraFilters.none),
          icon: PhosphorIcon(PhosphorIconsBold.arrowCounterClockwise, size: 14, color: C.accent),
          label: const Text('Reset', style: TextStyle(color: C.accent, fontWeight: FontWeight.w700)),
        ),
        children: [
          ValueSlider(icon: PhosphorIconsRegular.sun, label: 'Brightness', value: _filters.brightness, min: 0, max: 200, neutral: 100,
              format: (v) => v.round().toString(), onChanged: (v) => _setFilters(_filters.copyWith(brightness: v))),
          ValueSlider(icon: PhosphorIconsRegular.circleHalf, label: 'Contrast', value: _filters.contrast, min: 0, max: 200, neutral: 100,
              format: (v) => v.round().toString(), onChanged: (v) => _setFilters(_filters.copyWith(contrast: v))),
          ValueSlider(icon: PhosphorIconsRegular.drop, label: 'Saturation', value: _filters.saturation, min: 0, max: 200, neutral: 100,
              format: (v) => v.round().toString(), onChanged: (v) => _setFilters(_filters.copyWith(saturation: v))),
          ValueSlider(icon: PhosphorIconsRegular.dropHalfBottom, label: 'Blur', value: _filters.blur, min: 0, max: 10, neutral: 0,
              format: (v) => v.toStringAsFixed(1), onChanged: (v) => _setFilters(_filters.copyWith(blur: v))),
        ],
      ),
      PanelSection(
        title: 'Viewfinder aids',
        trailing: const Text('Phone only', style: T.caption),
        children: [
          PanelTile(
            icon: PhosphorIconsRegular.gridFour, title: 'Grid',
            subtitle: 'Rule-of-thirds guides',
            highlighted: _settings.gridOn,
            trailing: Switch(value: _settings.gridOn, onChanged: (v) => _updateSettings(_settings.copyWith(gridOn: v))),
          ),
          PanelTile(
            icon: PhosphorIconsRegular.ruler, title: 'Horizon level',
            subtitle: 'Turns green when the phone is level',
            highlighted: _settings.levelOn,
            trailing: Switch(value: _settings.levelOn, onChanged: _setLevel),
          ),
          PanelTile(
            icon: PhosphorIconsRegular.barricade, title: 'Zebra',
            subtitle: 'Red stripes on over-exposed areas',
            highlighted: _settings.zebraOn,
            trailing: Switch(value: _settings.zebraOn, onChanged: (v) => _setAids(zebra: v)),
          ),
          PanelTile(
            icon: PhosphorIconsRegular.crosshairSimple, title: 'Focus peaking',
            subtitle: 'Green outline on sharp edges',
            highlighted: _settings.peakingOn,
            trailing: Switch(value: _settings.peakingOn, onChanged: (v) => _setAids(peaking: v)),
          ),
        ],
      ),
      PanelSection(
        title: 'Stabilisation',
        children: [
          PanelTile(
            icon: PhosphorIconsRegular.handGrabbing, title: 'Steady shot',
            subtitle: _camera.isH264Mode ? 'Not available in H.264 mode' : 'Smooths hand shake (crops ~10%)',
            highlighted: _camera.stabilizeOn,
            trailing: Switch(value: _camera.stabilizeOn, onChanged: _camera.isH264Mode ? null : _setStabilize),
          ),
        ],
      ),
      PanelSection(
        title: 'Locks',
        children: [
          PanelTile(
            icon: PhosphorIconsRegular.crosshair, title: 'Focus lock',
            subtitle: _camera.focusLocked ? 'Holding focus distance' : 'Continuous autofocus',
            highlighted: _camera.focusLocked, highlightColor: C.warn,
            trailing: Switch(value: _camera.focusLocked, onChanged: (v) => _camera.setFocusLocked(v)),
          ),
          PanelTile(
            icon: PhosphorIconsRegular.sun, title: 'Exposure lock',
            subtitle: _camera.exposureLocked ? 'Holding brightness' : 'Auto exposure',
            highlighted: _camera.exposureLocked, highlightColor: C.warn,
            trailing: Switch(value: _camera.exposureLocked, onChanged: (v) => _camera.setExposureLocked(v)),
          ),
        ],
      ),
    ]);
  }

  void _disconnect() {
    context.read<ConnectionService>().disconnect();
    Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
  }

  // ── Full-screen states ──────────────────────────────────────────────────────
  Widget _startingView() => const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5, color: C.accent)),
          SizedBox(height: S.lg),
          Text('Starting camera…', style: T.label),
        ]),
      );

  Widget _stateView({required IconData icon, required Color color, required String title, required String body, required List<Widget> actions}) =>
      Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(S.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(R.lg)),
              child: PhosphorIcon(icon, size: 32, color: color),
            ),
            const SizedBox(height: S.lg),
            Text(title, style: T.title.copyWith(fontSize: 20), textAlign: TextAlign.center),
            const SizedBox(height: S.sm),
            Text(body, style: T.body, textAlign: TextAlign.center),
            const SizedBox(height: S.xl),
            Wrap(spacing: S.md, runSpacing: S.sm, alignment: WrapAlignment.center, children: actions),
          ]),
        ),
      ));

  Widget _permissionDeniedView() => _stateView(
        icon: PhosphorIconsFill.cameraSlash, color: C.warn,
        title: 'Camera access needed',
        body: 'Church Cam needs the camera to stream this phone to the desktop studio.',
        actions: [
          FilledButton.icon(onPressed: openCameraSettings, icon: PhosphorIcon(PhosphorIconsBold.gearSix, size: 16, color: C.accentInk), label: const Text('Open settings')),
          TextButton(onPressed: _disconnect, child: const Text('Back')),
        ],
      );

  Widget _errorView(String message) => _stateView(
        icon: PhosphorIconsFill.warningCircle, color: C.tally,
        title: 'Camera unavailable',
        body: message,
        actions: [FilledButton(onPressed: _disconnect, child: const Text('Back to connections'))],
      );
}

enum _Tab { live, shots, smart, image, studio, settings }

/// Zebra / focus-peaking overlay. The analysis image is in SOURCE orientation;
/// this applies the same mirror + rotation the encoder does so it lines up
/// with the preview.
class _AidsPainter extends CustomPainter {
  final ui.Image image;
  final Rect frameRect;
  final int rotation;
  final bool mirror;
  _AidsPainter({required this.image, required this.frameRect, required this.rotation, required this.mirror});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(frameRect.center.dx, frameRect.center.dy);
    canvas.rotate(rotation * math.pi / 180);
    if (mirror) canvas.scale(-1, 1);
    final sideways = rotation % 180 == 90;
    final w = sideways ? frameRect.height : frameRect.width;
    final h = sideways ? frameRect.width : frameRect.height;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromCenter(center: Offset.zero, width: w, height: h),
      Paint()..filterQuality = FilterQuality.none,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _AidsPainter old) =>
      old.image != image || old.frameRect != frameRect || old.rotation != rotation || old.mirror != mirror;
}

/// Rule-of-thirds guides over the picture that is actually SENT — i.e. the
/// zoom/Smart-Zoom crop, not the whole sensor frame. Follows the crop as it moves.
class _GridPainter extends CustomPainter {
  final CameraService camera;
  final Rect frameRect;
  _GridPainter(this.camera, this.frameRect) : super(repaint: camera.framingTick);

  @override
  void paint(Canvas canvas, Size size) {
    final c = camera.framer.crop;
    final r = Rect.fromLTWH(
      frameRect.left + c.left * frameRect.width, frameRect.top + c.top * frameRect.height,
      c.width * frameRect.width, c.height * frameRect.height,
    );
    final p = Paint()..color = const Color(0x66FFFFFF)..strokeWidth = 1;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var i = 1; i <= 2; i++) {
      final x = r.left + r.width * i / 3, y = r.top + r.height * i / 3;
      canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), p);
      canvas.drawLine(Offset(r.left, y), Offset(r.right, y), p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) => old.frameRect != frameRect;
}

/// Horizon level: a line that stays parallel to the real horizon, with fixed
/// reference ticks. Green within ±1°.
class _LevelPainter extends CustomPainter {
  final double tilt; // radians
  _LevelPainter(this.tilt);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final deg = tilt * 180 / math.pi;
    final level = deg.abs() < 1.0;
    final color = level ? C.ok : C.text;
    final half = size.width * 0.13;
    final ref = Paint()..color = const Color(0x99FFFFFF)..strokeWidth = 2..strokeCap = StrokeCap.round;
    canvas.drawLine(c + Offset(-half - 28, 0), c + Offset(-half - 8, 0), ref);
    canvas.drawLine(c + Offset(half + 8, 0), c + Offset(half + 28, 0), ref);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-tilt);
    canvas.drawLine(Offset(-half, 0), Offset(half, 0), Paint()..color = color..strokeWidth = level ? 3 : 2..strokeCap = StrokeCap.round);
    canvas.restore();
    if (!level) {
      final tp = TextPainter(
        text: TextSpan(text: '${deg.abs().toStringAsFixed(1)}°', style: T.hud.copyWith(color: C.text)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c + Offset(-tp.width / 2, 10));
    }
  }

  @override
  bool shouldRepaint(covariant _LevelPainter old) => (old.tilt - tilt).abs() > 0.0005;
}

/// Five-segment audio meter for the HUD.
class _MiniMeter extends StatelessWidget {
  final double level; // 0..1 RMS
  const _MiniMeter({required this.level});

  @override
  Widget build(BuildContext context) {
    // RMS → rough dBFS → 0..5 lit segments (-50 dB … -6 dB).
    final db = level <= 0 ? -90.0 : 20 * math.log(level) / math.ln10;
    final lit = ((db + 50) / 44 * 5).clamp(0, 5).round();
    return Row(mainAxisSize: MainAxisSize.min, children: List.generate(5, (i) {
      final on = i < lit;
      final col = i >= 4 ? C.tally : (i >= 3 ? C.warn : C.ok);
      return Container(
        width: 4, height: 6.0 + i * 2.5,
        margin: const EdgeInsets.only(left: 2),
        decoration: BoxDecoration(color: on ? col : C.surface3, borderRadius: BorderRadius.circular(1)),
      );
    }));
  }
}

/// Draws the Smart Zoom program frame over the full camera preview: everything
/// outside the crop is dimmed, the crop gets broadcast-style corner marks, and
/// the followed person gets a marker (amber when the tracker has lost them).
class _FramingPainter extends CustomPainter {
  final CameraService camera;
  final Rect frameRect;
  final bool showFrame;
  _FramingPainter({required this.camera, required this.frameRect, required this.showFrame})
      : super(repaint: camera.framingTick);

  Offset _toScreen(Offset p) => Offset(frameRect.left + p.dx * frameRect.width, frameRect.top + p.dy * frameRect.height);

  @override
  void paint(Canvas canvas, Size size) {
    if (!showFrame) return;
    final f = camera.framer;
    final c = f.crop;
    final r = Rect.fromPoints(_toScreen(c.topLeft), _toScreen(c.bottomRight));

    if (!f.isIdentity) {
      final dim = Paint()..color = const Color(0x8C000000);
      final outer = Path()..addRect(Offset.zero & size);
      final hole = Path()..addRect(r);
      canvas.drawPath(Path.combine(PathOperation.difference, outer, hole), dim);
    }

    // Corner marks.
    final cornerPaint = Paint()
      ..color = f.locked ? const Color(0xFFFFFFFF) : const Color(0xAAFFFFFF)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    final len = math.min(r.width, r.height) * 0.12;
    for (final corner in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      final sx = corner.dx == r.left ? 1.0 : -1.0;
      final sy = corner.dy == r.top ? 1.0 : -1.0;
      canvas.drawLine(corner, corner + Offset(len * sx, 0), cornerPaint);
      canvas.drawLine(corner, corner + Offset(0, len * sy), cornerPaint);
    }

    final s = f.subject;
    if (f.locked && s != null) {
      final lost = camera.tracker.lost;
      final p = _toScreen(s);
      final mark = Paint()
        ..color = lost ? const Color(0xFFF59E0B) : const Color(0xFF22C55E)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(p, 18, mark);
      canvas.drawCircle(p, 3, mark..style = PaintingStyle.fill);
    }
  }

  @override
  bool shouldRepaint(covariant _FramingPainter old) =>
      old.frameRect != frameRect || old.showFrame != showFrame || old.camera != camera;
}

class _FocusRing extends StatefulWidget {
  const _FocusRing();

  @override
  State<_FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<_FocusRing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 350))..forward();

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => ScaleTransition(
        scale: Tween(begin: 1.4, end: 1.0).animate(CurvedAnimation(parent: _c, curve: Curves.easeOut)),
        // Square AF bracket (camera-native), not a generic circle.
        child: Container(
          width: 72, height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(R.sm),
            border: Border.all(color: C.warn, width: 1.5),
          ),
          child: Center(child: Container(width: 4, height: 4, decoration: const BoxDecoration(color: C.warn, shape: BoxShape.circle))),
        ),
      );
}
