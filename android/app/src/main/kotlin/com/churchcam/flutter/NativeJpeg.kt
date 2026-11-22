package com.churchcam.flutter

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import java.io.ByteArrayOutputStream

/**
 * Camera YUV_420_888 planes → JPEG, using Android's built-in (libjpeg-turbo)
 * encoder. Roughly an order of magnitude faster than the pure-Dart encoder it
 * replaces, which was the main cap on frame rate and the main source of
 * per-frame delay on the phone.
 *
 * Crop (digital zoom / Smart Zoom), downscale, mirror and rotation are all
 * applied while building the NV21 buffer, in one pass, so the output frame is
 * exactly what the desktop should show — same semantics as the Dart encoder:
 * mirror first, then rotate clockwise by [rotation].
 */
object NativeJpeg {
    private var nv21 = ByteArray(0)
    private val out = ByteArrayOutputStream(256 * 1024)

    fun encode(
        y: ByteArray, u: ByteArray, v: ByteArray,
        srcW: Int, srcH: Int,
        yStride: Int, uvStride: Int, uvPixStride: Int,
        cropX: Double, cropY: Double, cropW: Double, cropH: Double,
        outW: Int, outH: Int,
        quality: Int, mirror: Boolean, rotation: Int,
    ): ByteArray {
        // Crop rectangle in source pixels.
        val cx0 = (cropX * srcW).toInt().coerceIn(0, srcW - 2)
        val cy0 = (cropY * srcH).toInt().coerceIn(0, srcH - 2)
        val cw = (cropW * srcW).toInt().coerceIn(2, srcW - cx0)
        val ch = (cropH * srcH).toInt().coerceIn(2, srcH - cy0)

        // Pre-rotation output size (rotation swaps axes for 90/270).
        val sideways = rotation == 90 || rotation == 270
        val pw = if (sideways) outH else outW
        val ph = if (sideways) outW else outH

        val need = outW * outH * 3 / 2
        if (nv21.size != need) nv21 = ByteArray(need)
        val buf = nv21

        // Source column/row for every pre-rotation coordinate (mirror applied).
        val colOf = IntArray(pw) { px ->
            val mx = if (mirror) pw - 1 - px else px
            cx0 + (mx.toLong() * cw / pw).toInt()
        }
        val rowOf = IntArray(ph) { py -> cy0 + (py.toLong() * ch / ph).toInt() }

        val ySize = y.size; val uSize = u.size; val vSize = v.size

        // ── Luma ──
        var o = 0
        for (oy in 0 until outH) {
            for (ox in 0 until outW) {
                val px: Int; val py: Int
                when (rotation) {
                    90 -> { px = oy; py = ph - 1 - ox }
                    180 -> { px = pw - 1 - ox; py = ph - 1 - oy }
                    270 -> { px = pw - 1 - oy; py = ox }
                    else -> { px = ox; py = oy }
                }
                val idx = rowOf[py] * yStride + colOf[px]
                buf[o++] = if (idx < ySize) y[idx] else 0
            }
        }

        // ── Chroma (NV21 = interleaved V,U at quarter resolution) ──
        var c = outW * outH
        var oy = 0
        while (oy < outH) {
            var ox = 0
            while (ox < outW) {
                val px: Int; val py: Int
                when (rotation) {
                    90 -> { px = oy; py = ph - 1 - ox }
                    180 -> { px = pw - 1 - ox; py = ph - 1 - oy }
                    270 -> { px = pw - 1 - oy; py = ox }
                    else -> { px = ox; py = oy }
                }
                val uvIdx = (rowOf[py] shr 1) * uvStride + (colOf[px] shr 1) * uvPixStride
                buf[c++] = if (uvIdx < vSize) v[uvIdx] else 128.toByte()
                buf[c++] = if (uvIdx < uSize) u[uvIdx] else 128.toByte()
                ox += 2
            }
            oy += 2
        }

        out.reset()
        YuvImage(buf, ImageFormat.NV21, outW, outH, null)
            .compressToJpeg(Rect(0, 0, outW, outH), quality, out)
        return out.toByteArray()
    }
}
