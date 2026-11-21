package com.churchcam.flutter

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.sqrt

/**
 * Microphone → 16-bit PCM, mono, 48 kHz, delivered in 20 ms chunks (1920 bytes).
 *
 * Raw PCM rather than AAC/Opus on purpose: on a LAN 96 KB/s is nothing, it
 * adds zero encode latency, and the desktop feeds it straight into ffmpeg's
 * s16le input with no decoder in between.
 *
 * The CAMCORDER source is tuned for recording a room (not a voice call), and
 * AGC / noise suppression are left OFF where possible — a church service has
 * music and choir that "voice cleanup" would mangle.
 */
class AudioStreamer(
    private val onChunk: (data: ByteArray, level: Float) -> Unit,
) {
    companion object {
        const val SAMPLE_RATE = 48_000
        const val CHUNK_SAMPLES = 960 // 20 ms
        private const val TAG = "AudioStreamer"
    }

    private val running = AtomicBoolean(false)
    private var thread: Thread? = null
    private var record: AudioRecord? = null

    @SuppressLint("MissingPermission") // checked on the Dart side before start()
    fun start(): Boolean {
        if (running.get()) return true
        val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuf <= 0) return false
        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.CAMCORDER,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf, CHUNK_SAMPLES * 2 * 4),
            )
        } catch (e: Exception) {
            Log.w(TAG, "AudioRecord init failed: ${e.message}")
            return false
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            return false
        }
        try { if (AutomaticGainControl.isAvailable()) AutomaticGainControl.create(rec.audioSessionId)?.enabled = false } catch (_: Exception) {}
        try { if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(rec.audioSessionId)?.enabled = false } catch (_: Exception) {}

        record = rec
        running.set(true)
        rec.startRecording()
        thread = Thread({
            val buf = ShortArray(CHUNK_SAMPLES)
            while (running.get()) {
                var read = 0
                while (read < CHUNK_SAMPLES && running.get()) {
                    val n = rec.read(buf, read, CHUNK_SAMPLES - read)
                    if (n <= 0) break
                    read += n
                }
                if (read <= 0) continue
                // Little-endian bytes + RMS level (0..1) for the meters.
                val out = ByteArray(read * 2)
                var sum = 0.0
                for (i in 0 until read) {
                    val s = buf[i].toInt()
                    out[i * 2] = (s and 0xFF).toByte()
                    out[i * 2 + 1] = ((s shr 8) and 0xFF).toByte()
                    sum += (s * s).toDouble()
                }
                val rms = sqrt(sum / read) / 32768.0
                onChunk(out, rms.toFloat())
            }
        }, "churchcam-audio").apply { priority = Thread.MAX_PRIORITY; start() }
        return true
    }

    fun stop() {
        running.set(false)
        try { thread?.join(300) } catch (_: Exception) {}
        thread = null
        try { record?.stop() } catch (_: Exception) {}
        try { record?.release() } catch (_: Exception) {}
        record = null
    }
}
