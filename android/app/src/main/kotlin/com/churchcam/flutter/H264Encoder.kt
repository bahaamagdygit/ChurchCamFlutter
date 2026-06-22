package com.churchcam.flutter

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Hardware H.264 encoder driven by YUV420 frames coming from the Flutter
 * `camera` plugin (via the Dart side). ByteBuffer input — we convert the
 * plugin's YUV_420_888 planes to the encoder's required color format, feed
 * MediaCodec, and emit Annex-B access units (config / keyframe / delta) with a
 * capture timestamp. The Dart side wraps each AU in the v2 wire frame.
 *
 * Why ByteBuffer (not Surface) input: the Flutter `camera` plugin exposes frames
 * as CPU byte planes, not a camera Surface, so Surface input isn't available
 * without replacing camera capture. ByteBuffer input still runs on the hardware
 * encoder block — it removes the pure-Dart JPEG bottleneck entirely.
 */
class H264Encoder(
    private val onEncoded: (type: Int, data: ByteArray, ptsUs: Long) -> Unit,
    private val onError: (String) -> Unit,
) {
    companion object {
        private const val TAG = "H264Encoder"
        const val TYPE_CONFIG = 0
        const val TYPE_KEY = 1
        const val TYPE_DELTA = 2
        private const val TIMEOUT_US = 10_000L
    }

    private var codec: MediaCodec? = null
    private val running = AtomicBoolean(false)
    private var colorFormat = MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
    private var width = 1280
    private var height = 720
    private var frameIndex = 0L

    // Reusable scratch buffer for the converted YUV (resized on configure).
    private var convertBuf: ByteArray = ByteArray(0)

    @Synchronized
    fun start(width: Int, height: Int, fps: Int, bitrate: Int) {
        stop()
        this.width = width
        this.height = height
        try {
            val mime = MediaFormat.MIMETYPE_VIDEO_AVC
            val format = MediaFormat.createVideoFormat(mime, width, height)

            // Choose a color format the device's encoder supports. Most support
            // COLOR_FormatYUV420Flexible (maps to NV12/I420 internally).
            colorFormat = pickColorFormat(mime)
            // COLOR_FormatYUV420SemiPlanar is interleaved chroma. Most device
            // encoders treat it as NV12 (U,V), but several Qualcomm/MediaTek ones
            // actually consume NV21 (V,U) — that mismatch was the green corruption.
            // Flexible maps to NV12 most reliably. Default NV21 for SemiPlanar.
            semiPlanarVU = colorFormat == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, colorFormat)
            format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            // Keyframe every 2s. Frequent IDRs eat the bitrate budget and starve
            // P-frames → blocky/blurry motion. 2s + on-demand resync is plenty.
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            // CBR keeps a STEADY bitrate so motion scenes don't spike past the
            // link capacity (the spike was the visible blur/stutter on motion).
            format.setInteger(MediaFormat.KEY_BITRATE_MODE,
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            // Baseline: no B-frames, simplest decode, lowest latency.
            format.setInteger(MediaFormat.KEY_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            format.setInteger(MediaFormat.KEY_LEVEL,
                MediaCodecInfo.CodecProfileLevel.AVCLevel41)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                format.setInteger(MediaFormat.KEY_LATENCY, 1)
                // Cap the encoder's internal queue so it can't build a backlog.
                format.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            }

            val c = MediaCodec.createEncoderByType(mime)
            c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            c.start()
            codec = c
            running.set(true)
            frameIndex = 0
            convertBuf = ByteArray(width * height * 3 / 2)
            Log.i(TAG, "[H264] STARTED ${width}x$height @${fps}fps ${bitrate / 1000}kbps CBR " +
                "colorFmt=$colorFormat chroma=${if (semiPlanarVU) "NV21(V,U)" else "NV12(U,V)"}")
        } catch (e: Exception) {
            Log.e(TAG, "start failed: ${e.message}")
            onError("encoder start: ${e.message}")
            stop()
        }
    }

    /** Dynamically change the target bitrate without a full reconfigure. */
    @Synchronized
    fun setBitrate(bitrate: Int) {
        val c = codec ?: return
        try {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrate)
            c.setParameters(params)
        } catch (e: Exception) {
            Log.w(TAG, "setBitrate failed: ${e.message}")
        }
    }

    /** Request an immediate keyframe (after reconnect / resolution change). */
    @Synchronized
    fun requestKeyframe() {
        val c = codec ?: return
        try {
            val params = android.os.Bundle()
            params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            c.setParameters(params)
        } catch (_: Exception) {}
    }

    /**
     * Encode one YUV_420_888 frame. Planes arrive as separate byte arrays with
     * the SOURCE strides (from Flutter's CameraImage). We copy into the encoder's
     * own input Image, honoring the ENCODER's destination strides — this is the
     * key fix for the diagonal-shear / blur distortion: the encoder's input
     * buffer is usually stride-padded, and blindly packing tight width×height
     * bytes corrupts every row. getInputImage() exposes the real strides.
     *
     * Non-blocking: dequeueInputBuffer with a 0 timeout. If no input buffer is
     * free the frame is DROPPED (returns) rather than blocking the caller —
     * realtime beats backlog.
     */
    @Synchronized
    fun encodeFrame(
        y: ByteArray, u: ByteArray, v: ByteArray,
        yStride: Int, uvStride: Int, uvPixelStride: Int,
        ptsUs: Long,
    ) {
        val c = codec ?: return
        if (!running.get()) return
        try {
            val inIndex = c.dequeueInputBuffer(0)  // 0 = don't block; drop if busy
            if (inIndex >= 0) {
                // Direct ByteBuffer path: pack a TIGHT (unpadded) NV12/NV21 buffer
                // of exactly width*height*3/2 bytes and pass that exact size to
                // queueInputBuffer. This is the proven path that produced a visible
                // image; getInputImage() was fragile across devices and broke frame
                // production. The semiPlanarVU flag fixes the U/V order (green).
                val input = c.getInputBuffer(inIndex)
                if (input != null) {
                    input.clear()
                    val packed = packYuv(y, u, v, yStride, uvStride, uvPixelStride)
                    input.put(packed, 0, width * height * 3 / 2)
                    c.queueInputBuffer(inIndex, 0, width * height * 3 / 2, ptsUs, 0)
                } else {
                    c.queueInputBuffer(inIndex, 0, 0, ptsUs, 0)
                }
            }
            drainOutput(c)
        } catch (e: Exception) {
            Log.e(TAG, "encodeFrame failed: ${e.message}")
            onError("encode: ${e.message}")
        }
    }

    private fun drainOutput(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val outIndex = c.dequeueOutputBuffer(info, 0)
            if (outIndex < 0) break
            val out = c.getOutputBuffer(outIndex)
            if (out != null && info.size > 0) {
                out.position(info.offset)
                out.limit(info.offset + info.size)
                val bytes = ByteArray(info.size)
                out.get(bytes)
                val type = when {
                    (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0 -> TYPE_CONFIG
                    (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0 -> TYPE_KEY
                    else -> TYPE_DELTA
                }
                if (type == TYPE_CONFIG) Log.i(TAG, "[H264] SPS/PPS config emitted (${bytes.size}B)")
                else if (type == TYPE_KEY) Log.i(TAG, "[H264] KEYFRAME emitted (${bytes.size}B)")
                onEncoded(type, bytes, info.presentationTimeUs)
            }
            c.releaseOutputBuffer(outIndex, false)
        }
    }

    /**
     * Convert YUV_420_888 source planes → a TIGHT (unpadded) semi-planar buffer
     * of exactly width*height*3/2 bytes: full Y plane, then interleaved chroma.
     *
     * Chroma order is controlled by [semiPlanarVU]:
     *   false → NV12 (U,V)   true → NV21 (V,U)
     * Writing the wrong order is exactly what produced the GREEN macroblock
     * corruption (luma right, chroma swapped). We pick the order from the chosen
     * encoder color format in start(); NV21 is the common correct choice for
     * COLOR_FormatYUV420SemiPlanar on the typical Qualcomm/MediaTek encoders.
     */
    private fun packYuv(
        y: ByteArray, u: ByteArray, v: ByteArray,
        yStride: Int, uvStride: Int, uvPixelStride: Int,
    ): ByteArray {
        val out = convertBuf
        val w = width; val h = height
        // Y plane — copy row by row honoring the SOURCE stride (strip padding).
        var o = 0
        for (row in 0 until h) {
            val src = row * yStride
            if (src + w <= y.size) System.arraycopy(y, src, out, o, w)
            o += w
        }
        // Interleaved chroma, half resolution.
        val cw = w / 2; val ch = h / 2
        var uvO = w * h
        for (row in 0 until ch) {
            val rowBase = row * uvStride
            var col = 0
            while (col < cw) {
                val idx = rowBase + col * uvPixelStride
                val up = if (idx < u.size) u[idx] else 0
                val vp = if (idx < v.size) v[idx] else 0
                if (semiPlanarVU) { out[uvO++] = vp; out[uvO++] = up }  // NV21 (V,U)
                else              { out[uvO++] = up; out[uvO++] = vp }  // NV12 (U,V)
                col++
            }
        }
        return out
    }

    // Chroma byte order for the packed semi-planar buffer (see packYuv). Set in
    // start() from the encoder's chosen color format. Defaults to NV21 because
    // that matched the device that showed green under the NV12 ordering.
    private var semiPlanarVU = true

    private fun pickColorFormat(mime: String): Int {
        try {
            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            for (ci in list.codecInfos) {
                if (!ci.isEncoder) continue
                if (!ci.supportedTypes.any { it.equals(mime, true) }) continue
                val caps = ci.getCapabilitiesForType(mime)
                for (cf in caps.colorFormats) {
                    if (cf == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible ||
                        cf == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar) {
                        return cf
                    }
                }
            }
        } catch (_: Exception) {}
        return MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
    }

    @Synchronized
    fun stop() {
        running.set(false)
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null
    }
}
