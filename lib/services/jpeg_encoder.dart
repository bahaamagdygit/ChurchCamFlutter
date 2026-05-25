import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// One camera frame's raw data, packaged to cross the isolate boundary.
/// Only plain data (typed lists + ints) is sent, so it copies cheaply and the
/// heavy YUV→RGB→JPEG work happens entirely off the UI isolate.
class RawFrame {
  final int format; // 0 = yuv420, 1 = bgra8888
  final int width;
  final int height;
  final int maxWidth; // longest output edge
  final int quality; // JPEG quality 0-100
  final bool mirror; // flip horizontally (front camera)

  // yuv420 planes
  final Uint8List? y, u, v;
  final int yRowStride, uvRowStride, uvPixelStride;

  // bgra single plane
  final Uint8List? bgra;

  const RawFrame({
    required this.format,
    required this.width,
    required this.height,
    required this.maxWidth,
    required this.quality,
    required this.mirror,
    this.y,
    this.u,
    this.v,
    this.yRowStride = 0,
    this.uvRowStride = 0,
    this.uvPixelStride = 1,
    this.bgra,
  });
}

class _Job {
  final RawFrame frame;
  final SendPort reply;
  const _Job(this.frame, this.reply);
}

/// A long-lived background isolate that encodes camera frames to JPEG.
/// Keep one instance for the whole streaming session — spawning per frame
/// would be far too slow.
class JpegEncoder {
  Isolate? _isolate;
  SendPort? _sendPort;
  final Completer<void> _ready = Completer<void>();
  ReceivePort? _initPort;

  Future<void> start() async {
    if (_isolate != null) return;
    _initPort = ReceivePort();
    _initPort!.listen((msg) {
      if (msg is SendPort) {
        _sendPort = msg;
        if (!_ready.isCompleted) _ready.complete();
      }
    });
    _isolate = await Isolate.spawn(_entry, _initPort!.sendPort);
    await _ready.future;
  }

  /// Encode one frame. Returns null if the encoder isn't ready or the frame is
  /// unusable. Each call uses its own reply port so concurrent calls are safe,
  /// though the caller should keep at most one in flight (backpressure).
  Future<Uint8List?> encode(RawFrame frame) async {
    final sp = _sendPort;
    if (sp == null) return null;
    final reply = ReceivePort();
    sp.send(_Job(frame, reply.sendPort));
    final result = await reply.first;
    reply.close();
    return result as Uint8List?;
  }

  void dispose() {
    _initPort?.close();
    _initPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
  }

  // ── isolate entry point ─────────────────────────────────────────────────────
  static void _entry(SendPort initReply) {
    final port = ReceivePort();
    initReply.send(port.sendPort);
    port.listen((msg) {
      if (msg is _Job) {
        Uint8List? out;
        try {
          out = _encode(msg.frame);
        } catch (_) {
          out = null;
        }
        msg.reply.send(out);
      }
    });
  }

  static Uint8List? _encode(RawFrame f) {
    img.Image rgb;
    if (f.format == 0) {
      // Downscale DURING the YUV read — never build the full-res image. This is
      // the single biggest latency win: at 1280→640 we touch 1/4 of the pixels.
      rgb = _yuvToImageScaled(f);
    } else {
      rgb = img.Image.fromBytes(
        width: f.width,
        height: f.height,
        bytes: f.bgra!.buffer,
        order: img.ChannelOrder.bgra,
      );
      final longest = rgb.width > rgb.height ? rgb.width : rgb.height;
      if (longest > f.maxWidth) {
        final scale = f.maxWidth / longest;
        rgb = img.copyResize(
          rgb,
          width: (rgb.width * scale).round(),
          height: (rgb.height * scale).round(),
          interpolation: img.Interpolation.nearest,
        );
      }
    }

    if (f.mirror) rgb = img.flipHorizontal(rgb);

    return img.encodeJpg(rgb, quality: f.quality);
  }

  /// YUV420 → RGB with integer nearest-neighbour downscaling baked into the read.
  /// We compute the output size from [maxWidth] and only sample the source pixels
  /// that map to an output pixel, using integer math (no float multiplies per px).
  static img.Image _yuvToImageScaled(RawFrame f) {
    final sw = f.width, sh = f.height;
    final longest = sw > sh ? sw : sh;
    // Integer downscale factor (1,2,3,…) so the longest edge ≤ maxWidth.
    int step = 1;
    while (longest ~/ step > f.maxWidth) {
      step++;
    }
    final ow = sw ~/ step, oh = sh ~/ step;
    final out = img.Image(width: ow, height: oh);

    final yB = f.y!, uB = f.u!, vB = f.v!;
    final yrs = f.yRowStride, uvrs = f.uvRowStride, uvps = f.uvPixelStride;

    for (int oy = 0; oy < oh; oy++) {
      final sy = oy * step;
      final yRow = sy * yrs;
      final uvRow = (sy >> 1) * uvrs;
      for (int ox = 0; ox < ow; ox++) {
        final sx = ox * step;
        final yIdx = yRow + sx;
        final uvIdx = uvRow + (sx >> 1) * uvps;
        if (yIdx >= yB.length || uvIdx >= uB.length || uvIdx >= vB.length) {
          continue;
        }
        final yp = yB[yIdx];
        final up = uB[uvIdx] - 128;
        final vp = vB[uvIdx] - 128;

        // Integer YUV→RGB (BT.601) — fixed-point, no floating multiplies.
        final r = yp + ((91881 * vp) >> 16);
        final g = yp - ((22554 * up + 46802 * vp) >> 16);
        final b = yp + ((116130 * up) >> 16);

        out.setPixelRgb(
          ox,
          oy,
          r < 0 ? 0 : (r > 255 ? 255 : r),
          g < 0 ? 0 : (g > 255 ? 255 : g),
          b < 0 ? 0 : (b > 255 ? 255 : b),
        );
      }
    }
    return out;
  }
}
