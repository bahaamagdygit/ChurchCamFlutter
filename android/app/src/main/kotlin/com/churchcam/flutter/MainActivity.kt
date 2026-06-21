package com.churchcam.flutter

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
    private var auSink: EventChannel.EventSink? = null

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
    }
}
