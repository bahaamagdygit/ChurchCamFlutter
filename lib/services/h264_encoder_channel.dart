import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One H.264 access unit emitted by the native encoder.
class H264Au {
  final int type; // 0 config | 1 key | 2 delta
  final int ptsUs;
  final Uint8List data; // Annex-B bytes
  const H264Au(this.type, this.ptsUs, this.data);
}

/// Dart wrapper around the native hardware H.264 encoder (see Kotlin
/// `H264Encoder` + `MainActivity` channels). Push YUV planes in via [encodeFrame];
/// receive Annex-B access units via [onAu].
///
/// This replaces the pure-Dart JPEG isolate when the desktop negotiates 'h264'.
class H264EncoderChannel {
  static const MethodChannel _ctrl = MethodChannel('churchcam/h264');
  static const EventChannel _au = EventChannel('churchcam/h264/au');

  void Function(H264Au au)? onAu;
  void Function(String reason)? onError;

  bool _started = false;
  bool get isStarted => _started;
  StreamSubscription<dynamic>? _sub;

  Future<bool> start({
    required int width,
    required int height,
    required int fps,
    required int bitrate,
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
      final ok = await _ctrl.invokeMethod<bool>('start', {
        'width': width,
        'height': height,
        'fps': fps,
        'bitrate': bitrate,
      });
      _started = ok ?? false;
      return _started;
    } catch (e) {
      debugPrint('[H264EncoderChannel] start failed: $e');
      onError?.call('start: $e');
      return false;
    }
  }

  // Only one encode call in flight across the channel at a time. If the native
  // side is still busy with the previous frame, DROP this one — piling up 1.4MB
  // MethodChannel calls is the main phone-side lag source.
  bool _encodeInFlight = false;

  /// Push one YUV_420_888 frame to the native encoder. Fire-and-forget: we do
  /// NOT await the round-trip (that serialized the whole pipeline). We only track
  /// completion to gate the next frame.
  void encodeFrame({
    required Uint8List y,
    required Uint8List u,
    required Uint8List v,
    required int yStride,
    required int uvStride,
    required int uvPixelStride,
    required int ptsUs,
  }) {
    if (!_started || _encodeInFlight) return;
    _encodeInFlight = true;
    _ctrl.invokeMethod('encodeFrame', {
      'y': y,
      'u': u,
      'v': v,
      'yStride': yStride,
      'uvStride': uvStride,
      'uvPixelStride': uvPixelStride,
      'ptsUs': ptsUs,
    }).catchError((e) {
      debugPrint('[H264EncoderChannel] encodeFrame error: $e');
    }).whenComplete(() {
      _encodeInFlight = false;
    });
  }

  Future<void> setBitrate(int bitrate) async {
    if (!_started) return;
    try {
      await _ctrl.invokeMethod('setBitrate', {'bitrate': bitrate});
    } catch (_) {}
  }

  Future<void> requestKeyframe() async {
    if (!_started) return;
    try {
      await _ctrl.invokeMethod('requestKeyframe');
    } catch (_) {}
  }

  Future<void> stop() async {
    _started = false;
    try {
      await _ctrl.invokeMethod('stop');
    } catch (_) {}
    await _sub?.cancel();
    _sub = null;
  }
}
