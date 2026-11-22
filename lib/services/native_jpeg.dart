import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'jpeg_encoder.dart';

/// Android's built-in JPEG encoder (see NativeJpeg.kt). Same input/output as
/// the Dart [JpegEncoder] isolate, ~10× faster, so the phone can hold 30 fps
/// with very little per-frame delay.
class NativeJpegEncoder {
  static const _ch = MethodChannel('churchcam/jpeg');
  bool _available = defaultTargetPlatform == TargetPlatform.android;

  bool get available => _available;

  /// Returns the JPEG, or null if the native path is unavailable (the caller
  /// then falls back to the Dart encoder for good).
  Future<Uint8List?> encode(RawFrame f) async {
    if (!_available || f.format != 0) return null;
    // Output size: longest edge ≤ maxWidth, never upscaled, even dimensions
    // (JPEG chroma subsampling needs them).
    final cropPxW = (f.cropW * f.width).round().clamp(2, f.width);
    final cropPxH = (f.cropH * f.height).round().clamp(2, f.height);
    final longest = cropPxW > cropPxH ? cropPxW : cropPxH;
    final scale = longest > f.maxWidth ? f.maxWidth / longest : 1.0;
    var w = ((cropPxW * scale).round() & ~1).clamp(2, 8192);
    var h = ((cropPxH * scale).round() & ~1).clamp(2, 8192);
    final sideways = f.rotation == 90 || f.rotation == 270;
    final outW = sideways ? h : w, outH = sideways ? w : h;
    try {
      return await _ch.invokeMethod<Uint8List>('encode', {
        'y': f.y, 'u': f.u, 'v': f.v,
        'w': f.width, 'h': f.height,
        'yStride': f.yRowStride, 'uvStride': f.uvRowStride, 'uvPixStride': f.uvPixelStride,
        'cropX': f.cropX, 'cropY': f.cropY, 'cropW': f.cropW, 'cropH': f.cropH,
        'outW': outW, 'outH': outH,
        'quality': f.quality, 'mirror': f.mirror, 'rotation': f.rotation,
      });
    } on MissingPluginException {
      _available = false;
      return null;
    } catch (e) {
      debugPrint('[NativeJpeg] encode failed, falling back to Dart encoder: $e');
      _available = false;
      return null;
    }
  }
}
