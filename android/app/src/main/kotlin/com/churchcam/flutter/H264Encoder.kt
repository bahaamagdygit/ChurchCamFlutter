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
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, colorFormat)
            format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // keyframe every 1s
            format.setInteger(MediaFormat.KEY_BITRATE_MODE,
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            // Baseline keeps decode simple & latency low on the desktop side.
            format.setInteger(MediaFormat.KEY_PROFILE,
                MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                format.setInteger(MediaFormat.KEY_LATENCY, 1)
            }

            val c = MediaCodec.createEncoderByType(mime)
            c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            c.start()
            codec = c
            running.set(true)
            frameIndex = 0
            convertBuf = ByteArray(width * height * 3 / 2)
            Log.i(TAG, "encoder started ${width}x$height @${fps}fps ${bitrate}bps colorFmt=$colorFormat")
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
     * strides (matching CameraImage). We pack to the encoder's color format,
     * queue the input buffer, then drain any output AUs.
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
            val inIndex = c.dequeueInputBuffer(TIMEOUT_US)
            if (inIndex >= 0) {
                val input = c.getInputBuffer(inIndex) ?: return
                input.clear()
                val packed = packYuv(y, u, v, yStride, uvStride, uvPixelStride)
                input.put(packed, 0, width * height * 3 / 2)
                c.queueInputBuffer(inIndex, 0, width * height * 3 / 2, ptsUs, 0)
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
                onEncoded(type, bytes, info.presentationTimeUs)
            }
            c.releaseOutputBuffer(outIndex, false)
        }
    }

    /**
     * Convert YUV_420_888 planes → the encoder's planar/semi-planar layout.
     * COLOR_FormatYUV420Flexible accepts NV12 (Y plane + interleaved UV). We
     * write NV12: full Y, then interleaved V/U? No — NV12 is U then V. We honor
     * the source pixel/row strides while packing tightly to width×height.
     */
    private fun packYuv(
        y: ByteArray, u: ByteArray, v: ByteArray,
        yStride: Int, uvStride: Int, uvPixelStride: Int,
    ): ByteArray {
        val out = convertBuf
        val w = width; val h = height
        // Y plane — copy row by row honoring stride.
        var o = 0
        for (row in 0 until h) {
            val src = row * yStride
            System.arraycopy(y, src, out, o, w)
            o += w
        }
        // UV plane (NV12 = interleaved U,V), half resolution.
        val cw = w / 2; val ch = h / 2
        var uvO = w * h
        for (row in 0 until ch) {
            val uRow = row * uvStride
            val vRow = row * uvStride
            var col = 0
            while (col < cw) {
                val uIdx = uRow + col * uvPixelStride
                val vIdx = vRow + col * uvPixelStride
                out[uvO++] = if (uIdx < u.size) u[uIdx] else 0
                out[uvO++] = if (vIdx < v.size) v[vIdx] else 0
                col++
            }
        }
        return out
    }

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
