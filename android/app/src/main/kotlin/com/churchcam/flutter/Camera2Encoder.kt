package com.churchcam.flutter

import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.*
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import android.view.Surface
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * ZERO-COPY H.264 capture+encode. Camera2 renders frames DIRECTLY into the
 * MediaCodec input Surface — no YUV bytes ever cross into Dart, so there is NO
 * chroma/stride mismatch and NO green corruption. This is the reliable path to
 * 4K H.264 that the ByteBuffer approach could never guarantee.
 *
 *   Camera2 (chosen lens) ──▶ MediaCodec input Surface ──▶ Annex-B AUs ──▶ Dart
 *
 * The encoder's Surface is the camera target; the hardware ISP + encoder do all
 * the colour conversion internally and correctly.
 */
class Camera2Encoder(
    private val context: Context,
    private val onEncoded: (type: Int, data: ByteArray, ptsUs: Long) -> Unit,
    private val onError: (String) -> Unit,
) {
    companion object {
        private const val TAG = "Camera2Encoder"
        const val TYPE_CONFIG = 0
        const val TYPE_KEY = 1
        const val TYPE_DELTA = 2
    }

    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var codec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private val running = AtomicBoolean(false)

    private var bgThread: HandlerThread? = null
    private var bgHandler: Handler? = null

    private var width = 1920
    private var height = 1080
    private var fps = 30
    private var bitrate = 6_000_000
    private var cameraId: String = ""
    private var sensorOrientation = 90

    // The Dart side may attach a preview SurfaceTexture; we add it as a second
    // camera target so the operator sees the live camera on the phone.
    private var previewSurface: Surface? = null

    fun setPreviewSurface(s: Surface?) { previewSurface = s }

    /** cameraId: "" = default back camera; else a specific Camera2 id (lens). */
    @Synchronized
    fun start(width: Int, height: Int, fps: Int, bitrate: Int, cameraId: String, facingFront: Boolean) {
        stop()
        this.width = width; this.height = height; this.fps = fps; this.bitrate = bitrate
        try {
            startBg()
            this.cameraId = resolveCameraId(cameraId, facingFront)
            val chars = cameraManager.getCameraCharacteristics(this.cameraId)
            sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
            val chosen = chooseSize(chars, width, height)
            this.width = chosen.width; this.height = chosen.height

            setupEncoder(this.width, this.height, fps, bitrate)
            openCamera()
            Log.i(TAG, "[Cam2] start ${this.width}x${this.height}@${fps} br=${bitrate/1000}k id=${this.cameraId} sensorOri=$sensorOrientation")
        } catch (e: Exception) {
            Log.e(TAG, "start failed: ${e.message}")
            onError("cam2 start: ${e.message}")
            stop()
        }
    }

    private fun setupEncoder(w: Int, h: Int, fps: Int, bitrate: Int) {
        val mime = MediaFormat.MIMETYPE_VIDEO_AVC
        val fmt = MediaFormat.createVideoFormat(mime, w, h)
        // Surface input → the encoder consumes GPU frames directly.
        fmt.setInteger(MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        fmt.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
        fmt.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
        fmt.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        fmt.setInteger(MediaFormat.KEY_BITRATE_MODE,
            MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
        fmt.setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            fmt.setInteger(MediaFormat.KEY_LATENCY, 1)
            fmt.setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
        }
        val c = MediaCodec.createEncoderByType(mime)
        c.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = c.createInputSurface()
        c.setCallback(object : MediaCodec.Callback() {
            override fun onOutputBufferAvailable(mc: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                try {
                    val out = mc.getOutputBuffer(index)
                    if (out != null && info.size > 0) {
                        out.position(info.offset); out.limit(info.offset + info.size)
                        val bytes = ByteArray(info.size); out.get(bytes)
                        val type = when {
                            (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0 -> TYPE_CONFIG
                            (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0 -> TYPE_KEY
                            else -> TYPE_DELTA
                        }
                        onEncoded(type, bytes, info.presentationTimeUs)
                    }
                    mc.releaseOutputBuffer(index, false)
                } catch (e: Exception) { Log.w(TAG, "output err: ${e.message}") }
            }
            override fun onInputBufferAvailable(mc: MediaCodec, index: Int) {}
            override fun onError(mc: MediaCodec, e: MediaCodec.CodecException) {
                Log.e(TAG, "codec error: ${e.message}"); onError("codec: ${e.message}")
            }
            override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {}
        }, bgHandler)
        c.start()
        codec = c
        running.set(true)
    }

    @android.annotation.SuppressLint("MissingPermission")
    private fun openCamera() {
        cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(device: CameraDevice) {
                cameraDevice = device
                createSession()
            }
            override fun onDisconnected(device: CameraDevice) { device.close(); cameraDevice = null }
            override fun onError(device: CameraDevice, error: Int) {
                device.close(); cameraDevice = null; onError("camera open error $error")
            }
        }, bgHandler)
    }

    private fun createSession() {
        val device = cameraDevice ?: return
        val encSurface = inputSurface ?: return
        val targets = mutableListOf(encSurface)
        previewSurface?.let { targets.add(it) }

        val reqBuilder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
        for (t in targets) reqBuilder.addTarget(t)
        // Steady frame rate for the encoder.
        reqBuilder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, android.util.Range(fps, fps))

        val cb = object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(session: CameraCaptureSession) {
                captureSession = session
                try {
                    session.setRepeatingRequest(reqBuilder.build(), null, bgHandler)
                } catch (e: Exception) { onError("repeating req: ${e.message}") }
            }
            override fun onConfigureFailed(session: CameraCaptureSession) {
                onError("session configure failed")
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val cfgs = targets.map { OutputConfiguration(it) }
            val sessionCfg = SessionConfiguration(
                SessionConfiguration.SESSION_REGULAR, cfgs,
                Executors.newSingleThreadExecutor(), cb)
            device.createCaptureSession(sessionCfg)
        } else {
            @Suppress("DEPRECATION")
            device.createCaptureSession(targets, cb, bgHandler)
        }
    }

    fun requestKeyframe() {
        val c = codec ?: return
        try {
            val b = android.os.Bundle()
            b.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
            c.setParameters(b)
        } catch (_: Exception) {}
    }

    fun setBitrate(br: Int) {
        val c = codec ?: return
        try {
            val b = android.os.Bundle()
            b.putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, br)
            c.setParameters(b)
        } catch (_: Exception) {}
    }

    /** Sensor orientation so Dart/desktop can rotate the feed to match the phone. */
    fun getSensorOrientation(): Int = sensorOrientation

    private fun resolveCameraId(requested: String, facingFront: Boolean): String {
        if (requested.isNotEmpty()) return requested
        val want = if (facingFront) CameraCharacteristics.LENS_FACING_FRONT
                   else CameraCharacteristics.LENS_FACING_BACK
        for (id in cameraManager.cameraIdList) {
            val f = cameraManager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
            if (f == want) return id
        }
        return cameraManager.cameraIdList.firstOrNull() ?: "0"
    }

    private fun chooseSize(chars: CameraCharacteristics, w: Int, h: Int): Size {
        val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: return Size(w, h)
        val sizes = map.getOutputSizes(MediaCodec::class.java) ?: return Size(w, h)
        // Exact match first; else the closest not exceeding the request; else max.
        sizes.firstOrNull { it.width == w && it.height == h }?.let { return it }
        val under = sizes.filter { it.width <= w && it.height <= h }
            .maxByOrNull { it.width.toLong() * it.height }
        return under ?: sizes.maxByOrNull { it.width.toLong() * it.height } ?: Size(w, h)
    }

    private fun startBg() {
        bgThread = HandlerThread("Cam2Enc").also { it.start() }
        bgHandler = Handler(bgThread!!.looper)
    }

    @Synchronized
    fun stop() {
        running.set(false)
        try { captureSession?.close() } catch (_: Exception) {}
        captureSession = null
        try { cameraDevice?.close() } catch (_: Exception) {}
        cameraDevice = null
        try { codec?.stop(); codec?.release() } catch (_: Exception) {}
        codec = null
        try { inputSurface?.release() } catch (_: Exception) {}
        inputSurface = null
        try { bgThread?.quitSafely() } catch (_: Exception) {}
        bgThread = null; bgHandler = null
    }
}
