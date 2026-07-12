import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'h264_encoder_channel.dart' show H264Au;

/// Dart wrapper around the native ZERO-COPY Camera2 encoder. Unlike the
/// ByteBuffer path, the camera renders straight into the encoder Surface, so no
/// YUV crosses the channel — this eliminates the green corruption entirely and
/// enables reliable 4K. AUs arrive on the SAME EventChannel the ByteBuffer path
/// uses (`churchcam/h264/au`), so the wire/framing code is unchanged.
class Cam2EncoderChannel {
  static const MethodChannel _ctrl = MethodChannel('churchcam/cam2');
  static const EventChannel _au = EventChannel('churchcam/h264/au');

  void Function(H264Au au)? onAu;
  void Function(String reason)? onError;

  bool _started = false;
  bool get isStarted => _started;
  int _sensorOrientation = 90;
  int get sensorOrientation => _sensorOrientation;
  StreamSubscription<dynamic>? _sub;

  Future<bool> start({
    required int width,
    required int height,
    required int fps,
    required int bitrate,
    String cameraId = '',
    bool front = false,
  }) async {
    try {
      _sub ??= _au.receiveBroadcastStream().listen(
        (event) {
          if (event is Map) {
            final type = (event['type'] as num?)?.toInt() ?? 2;
            final pts = (event['ptsUs'] as num?)?.toInt() ?? 0;
            final data = event['data'];
            if (data is Uint8List) {
              onAu?.call(H264Au(type, pts, data));
            } else if (data is List<int>) {
              onAu?.call(H264Au(type, pts, Uint8List.fromList(data)));
            }
          }
        },
        onError: (e) => onError?.call('au stream: $e'),
      );
      final res = await _ctrl.invokeMethod('start', {
        'width': width,
        'height': height,
        'fps': fps,
        'bitrate': bitrate,
        'cameraId': cameraId,
        'front': front,
      });
      if (res is Map && res['sensorOrientation'] is int) {
        _sensorOrientation = res['sensorOrientation'] as int;
      }
      _started = true;
      return true;
    } catch (e) {
      debugPrint('[Cam2EncoderChannel] start failed: $e');
      onError?.call('start: $e');
      return false;
    }
  }

  Future<void> setBitrate(int bitrate) async {
    if (!_started) return;
    try { await _ctrl.invokeMethod('setBitrate', {'bitrate': bitrate}); } catch (_) {}
  }

  Future<void> requestKeyframe() async {
    if (!_started) return;
    try { await _ctrl.invokeMethod('requestKeyframe'); } catch (_) {}
  }

  Future<void> stop() async {
    _started = false;
    try { await _ctrl.invokeMethod('stop'); } catch (_) {}
    await _sub?.cancel();
    _sub = null;
  }
}
