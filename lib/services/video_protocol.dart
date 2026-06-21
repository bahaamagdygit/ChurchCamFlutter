import 'dart:typed_data';

/// Church Bridge video wire protocol — MUST stay byte-compatible with the
/// desktop `electron/video-protocol.ts`. Frames travel over the TCP video
/// socket AFTER the 32-byte ASCII deviceId header.
///
///   • LEGACY (mjpeg): [4-byte BE length][JPEG]      — unchanged default.
///   • V2 (h264):      [16-byte header][Annex-B AU].
///
/// V2 header (16 bytes, big-endian):
///   0  1  magic       = 0xCB
///   1  1  type        = 0 config | 1 keyframe | 2 delta
///   2  2  flags       = bit0 mirror; bits1-2 rotation idx (0..3 → 0/90/180/270)
///   4  8  captureTsUs = phone monotonic capture time, microseconds
///  12  4  payloadLen
///  16  N  payload (Annex-B AU; config = SPS+PPS)

const int kV2Magic = 0xCB;
const int kV2HeaderLen = 16;

enum V2FrameType { config, key, delta }

int _typeByte(V2FrameType t) {
  switch (t) {
    case V2FrameType.config:
      return 0;
    case V2FrameType.key:
      return 1;
    case V2FrameType.delta:
      return 2;
  }
}

int _rotationIdx(int rotation) {
  switch (rotation) {
    case 90:
      return 1;
    case 180:
      return 2;
    case 270:
      return 3;
    default:
      return 0;
  }
}

/// Build a V2 frame: 16-byte header + payload, as a single contiguous buffer
/// (one socket write → one syscall, matching the legacy sendFrame path).
Uint8List encodeV2Frame({
  required V2FrameType type,
  required Uint8List payload,
  required int captureTsUs,
  bool mirror = false,
  int rotation = 0,
}) {
  final out = Uint8List(kV2HeaderLen + payload.length);
  final bd = ByteData.sublistView(out);
  bd.setUint8(0, kV2Magic);
  bd.setUint8(1, _typeByte(type));
  int flags = 0;
  if (mirror) flags |= 0x0001;
  flags |= (_rotationIdx(rotation) & 0x03) << 1;
  bd.setUint16(2, flags, Endian.big);
  bd.setUint64(4, captureTsUs, Endian.big);
  bd.setUint32(12, payload.length, Endian.big);
  out.setRange(kV2HeaderLen, kV2HeaderLen + payload.length, payload);
  return out;
}

/// Build a LEGACY MJPEG frame: 4-byte BE length + JPEG bytes (unchanged format,
/// kept here so both encoders share one module).
Uint8List encodeLegacyFrame(Uint8List jpeg) {
  final len = jpeg.length;
  final out = Uint8List(4 + len);
  out[0] = (len >> 24) & 0xFF;
  out[1] = (len >> 16) & 0xFF;
  out[2] = (len >> 8) & 0xFF;
  out[3] = len & 0xFF;
  out.setRange(4, 4 + len, jpeg);
  return out;
}
