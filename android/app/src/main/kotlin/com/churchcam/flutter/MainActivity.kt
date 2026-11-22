package com.churchcam.flutter

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.net.wifi.WifiManager
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges the Dart side to the native hardware [H264Encoder].
 *
 *   • MethodChannel "churchcam/h264"  — start / stop / setBitrate /
 *     requestKeyframe / encodeFrame (Dart pushes YUV planes here).
 *   • EventChannel  "churchcam/h264/au" — encoder pushes Annex-B access units
 *     (type 0/1/2 + ptsUs) back to Dart, which frames them for the wire.
 *
 * AUs are delivered as a Map { type:Int, pts:Long(ms-as-double via int), data:ByteArray }.
 */
class MainActivity : FlutterActivity() {
    private var encoder: H264Encoder? = null
    private var cam2: Camera2Encoder? = null
    private var auSink: EventChannel.EventSink? = null
    private var audio: AudioStreamer? = null
    private var audioSink: EventChannel.EventSink? = null
    private val jpegExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private var wifiLock: WifiManager.WifiLock? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "churchcam/h264/au").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    auSink = events
                }
                override fun onCancel(args: Any?) {
                    auSink = null
                }
            }
        )

        // Device info channel — WiFi signal strength (RSSI → 0..4 bars + dBm).
        // Hardware-speed JPEG encoding for the MJPEG stream (see NativeJpeg).
        // Runs on its own thread so the platform thread never stalls.
        MethodChannel(messenger, "churchcam/jpeg").setMethodCallHandler { call, result ->
            if (call.method != "encode") { result.notImplemented(); return@setMethodCallHandler }
            val a = call.arguments as? Map<*, *>
            if (a == null) { result.error("args", "missing", null); return@setMethodCallHandler }
            jpegExecutor.execute {
                try {
                    val jpeg = NativeJpeg.encode(
                        a["y"] as ByteArray, a["u"] as ByteArray, a["v"] as ByteArray,
                        (a["w"] as Number).toInt(), (a["h"] as Number).toInt(),
                        (a["yStride"] as Number).toInt(), (a["uvStride"] as Number).toInt(),
                        (a["uvPixStride"] as Number).toInt(),
                        (a["cropX"] as Number).toDouble(), (a["cropY"] as Number).toDouble(),
                        (a["cropW"] as Number).toDouble(), (a["cropH"] as Number).toDouble(),
                        (a["outW"] as Number).toInt(), (a["outH"] as Number).toInt(),
                        (a["quality"] as Number).toInt(), a["mirror"] == true,
                        (a["rotation"] as Number).toInt(),
                    )
                    mainHandler.post { result.success(jpeg) }
                } catch (e: Throwable) {
                    mainHandler.post { result.error("encode", e.message, null) }
                }
            }
        }

        // Keep Wi-Fi out of power-save while streaming. Android otherwise
        // naps the radio between packets, which shows up as bursty frames and
        // 100–300 ms latency spikes.
        MethodChannel(messenger, "churchcam/net").setMethodCallHandler { call, result ->
            when (call.method) {
                "wifiLock" -> {
                    val on = call.arguments == true
                    try {
                        if (on) {
                            if (wifiLock == null) {
                                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                                @Suppress("DEPRECATION")
                                val mode = if (android.os.Build.VERSION.SDK_INT >= 29)
                                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
                                wifiLock = wm.createWifiLock(mode, "churchcam:stream").apply { setReferenceCounted(false) }
                            }
                            if (wifiLock?.isHeld != true) wifiLock?.acquire()
                        } else {
                            if (wifiLock?.isHeld == true) wifiLock?.release()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Microphone PCM for the desktop's stream audio (see AudioStreamer).
        EventChannel(messenger, "churchcam/audio/pcm").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) { audioSink = events }
                override fun onCancel(args: Any?) { audioSink = null }
            }
        )
        MethodChannel(messenger, "churchcam/audio").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    audio?.stop()
                    audio = AudioStreamer { data, level ->
                        runOnUiThread { audioSink?.success(mapOf("data" to data, "level" to level.toDouble())) }
                    }
                    result.success(audio?.start() == true)
                }
                "stop" -> { audio?.stop(); audio = null; result.success(true) }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "churchcam/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "wifiSignal" -> {
                    try {
                        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        @Suppress("DEPRECATION")
                        val info = wm.connectionInfo
                        val rssi = info?.rssi ?: -127
                        // Android's standard 0..4 bar mapping.
                        @Suppress("DEPRECATION")
                        val bars = WifiManager.calculateSignalLevel(rssi, 5)
                        result.success(mapOf("rssi" to rssi, "bars" to bars))
                    } catch (e: Exception) {
                        result.success(mapOf("rssi" to -127, "bars" to 0))
                    }
                }
                "thermal" -> {
                    // Battery temperature (tenths of °C from the sticky battery
                    // broadcast) + the OS thermal status (API 29+: 0 none … 6
                    // shutdown). Both are cheap; polled every 5 s.
                    var tempC = -1.0
                    try {
                        val i = applicationContext.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                        val t = i?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE) ?: Int.MIN_VALUE
                        if (t != Int.MIN_VALUE) tempC = t / 10.0
                    } catch (_: Exception) {}
                    var status = -1
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        try {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            status = pm.currentThermalStatus
                        } catch (_: Exception) {}
                    }
                    result.success(mapOf("tempC" to tempC, "status" to status))
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "churchcam/h264").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val w = call.argument<Int>("width") ?: 1280
                    val h = call.argument<Int>("height") ?: 720
                    val fps = call.argument<Int>("fps") ?: 30
                    val bitrate = call.argument<Int>("bitrate") ?: 3_000_000
                    encoder?.stop()
                    encoder = H264Encoder(
                        onEncoded = { type, data, ptsUs ->
                            // Hop to the platform main thread for the event sink.
                            runOnUiThread {
                                auSink?.success(
                                    mapOf(
                                        "type" to type,
                                        "ptsUs" to ptsUs,
                                        "data" to data,
                                    )
                                )
                            }
                        },
                        onError = { msg ->
                            runOnUiThread { auSink?.error("ENCODER", msg, null) }
                        },
                    )
                    encoder?.start(w, h, fps, bitrate)
                    result.success(true)
                }
                "stop" -> {
                    encoder?.stop()
                    encoder = null
                    result.success(true)
                }
                "setBitrate" -> {
                    val br = call.argument<Int>("bitrate") ?: return@setMethodCallHandler result.success(false)
                    encoder?.setBitrate(br)
                    result.success(true)
                }
                "requestKeyframe" -> {
                    encoder?.requestKeyframe()
                    result.success(true)
                }
                "encodeFrame" -> {
                    val enc = encoder
                    if (enc == null) { result.success(false); return@setMethodCallHandler }
                    val y = call.argument<ByteArray>("y")
                    val u = call.argument<ByteArray>("u")
                    val v = call.argument<ByteArray>("v")
                    val yStride = call.argument<Int>("yStride") ?: 0
                    val uvStride = call.argument<Int>("uvStride") ?: 0
                    val uvPixelStride = call.argument<Int>("uvPixelStride") ?: 1
                    val ptsUs = (call.argument<Number>("ptsUs") ?: 0L).toLong()
                    if (y == null || u == null || v == null) {
                        result.success(false); return@setMethodCallHandler
                    }
                    enc.encodeFrame(y, u, v, yStride, uvStride, uvPixelStride, ptsUs)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // ── Camera2 zero-copy encoder (churchcam/cam2) ───────────────────────
        // Camera renders directly into the encoder Surface — no YUV crosses to
        // Dart, so there is no chroma/green issue. AUs come back on the SAME
        // EventChannel (churchcam/h264/au) so the Dart receiver is unchanged.
        MethodChannel(messenger, "churchcam/cam2").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val w = call.argument<Int>("width") ?: 1920
                    val h = call.argument<Int>("height") ?: 1080
                    val fps = call.argument<Int>("fps") ?: 30
                    val bitrate = call.argument<Int>("bitrate") ?: 6_000_000
                    val cameraId = call.argument<String>("cameraId") ?: ""
                    val front = call.argument<Boolean>("front") ?: false
                    cam2?.stop()
                    cam2 = Camera2Encoder(
                        applicationContext,
                        onEncoded = { type, data, ptsUs ->
                            runOnUiThread {
                                auSink?.success(mapOf("type" to type, "ptsUs" to ptsUs, "data" to data))
                            }
                        },
                        onError = { msg -> runOnUiThread { auSink?.error("CAM2", msg, null) } },
                    )
                    cam2?.start(w, h, fps, bitrate, cameraId, front)
                    result.success(mapOf("sensorOrientation" to (cam2?.getSensorOrientation() ?: 90)))
                }
                "stop" -> { cam2?.stop(); cam2 = null; result.success(true) }
                "setBitrate" -> {
                    val br = call.argument<Int>("bitrate") ?: return@setMethodCallHandler result.success(false)
                    cam2?.setBitrate(br); result.success(true)
                }
                "requestKeyframe" -> { cam2?.requestKeyframe(); result.success(true) }
                "sensorOrientation" -> result.success(cam2?.getSensorOrientation() ?: 90)
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        try { cam2?.stop() } catch (_: Exception) {}
        try { encoder?.stop() } catch (_: Exception) {}
        try { audio?.stop() } catch (_: Exception) {}
        try { if (wifiLock?.isHeld == true) wifiLock?.release() } catch (_: Exception) {}
        jpegExecutor.shutdown()
        super.onDestroy()
    }
}
