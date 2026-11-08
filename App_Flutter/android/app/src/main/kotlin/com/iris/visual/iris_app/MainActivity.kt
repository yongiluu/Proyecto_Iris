package com.iris.visual.iris_app

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.iris.visual.iris_app/volume"
    private val SOUND_CHANNEL = "com.iris.visual.iris_app/sound"
    private var methodChannel: MethodChannel? = null
    // Se reutiliza para los pitidos de cercania (hasta 4 por segundo).
    private var proximityTone: ToneGenerator? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        // Aviso sonoro de "consulta enviada". Va por el canal de musica (como la voz de Iris),
        // asi suena aunque el celular este en silencio.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SOUND_CHANNEL).setMethodCallHandler { call, result ->
            // Cercania, como sensor de retroceso: nivel 1 tono medio, nivel 2 mas agudo y largo.
            if (call.method == "proximity") {
                try {
                    val level = call.argument<Int>("level") ?: 1
                    val tone = proximityTone ?: ToneGenerator(AudioManager.STREAM_MUSIC, 100).also { proximityTone = it }
                    if (level >= 2) tone.startTone(ToneGenerator.TONE_DTMF_D, 90)
                    else tone.startTone(ToneGenerator.TONE_DTMF_5, 70)
                    result.success(null)
                } catch (e: RuntimeException) {
                    result.error("TONE", e.message, null)
                }
                return@setMethodCallHandler
            }
            // Tono de una frecuencia dada (detector de luz del celular: mas agudo = mas luz).
            if (call.method == "pitch") {
                val hz = (call.argument<Int>("hz") ?: 440).coerceIn(80, 4000)
                val ms = (call.argument<Int>("ms") ?: 120).coerceIn(20, 1000)
                Thread { playPitch(hz, ms) }.start()
                result.success(null)
                return@setMethodCallHandler
            }
            // querySent = doble pitido (consulta enviada); listening = un pitido (Iris escucha).
            val toneType = when (call.method) {
                "querySent" -> ToneGenerator.TONE_PROP_ACK
                "listening" -> ToneGenerator.TONE_PROP_BEEP
                "thinking" -> ToneGenerator.TONE_CDMA_PIP
                else -> null
            }
            if (toneType != null) {
                try {
                    val tone = ToneGenerator(AudioManager.STREAM_MUSIC, 90)
                    tone.startTone(toneType, 300)
                    Handler(Looper.getMainLooper()).postDelayed({ tone.release() }, 500)
                    result.success(null)
                } catch (e: RuntimeException) {
                    result.error("TONE", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun playPitch(hz: Int, ms: Int) {
        try {
            val rate = 22050
            val n = rate * ms / 1000
            val fade = minOf(n / 4, rate / 200) // 5 ms de entrada y salida: sin chasquidos
            val samples = ShortArray(n) { i ->
                val env = when {
                    i < fade -> i.toDouble() / fade
                    i > n - fade -> (n - i).toDouble() / fade
                    else -> 1.0
                }
                (Math.sin(2.0 * Math.PI * hz * i / rate) * env * 0.6 * Short.MAX_VALUE).toInt().toShort()
            }
            val track = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
                .setAudioFormat(AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(n * 2)
                .build()
            track.write(samples, 0, n)
            track.play()
            Thread.sleep(ms.toLong() + 30)
            track.release()
        } catch (e: Exception) {
            // Sin audio no hay nada que hacer; el detector sigue vibrando.
        }
    }

    override fun onDestroy() {
        proximityTone?.release()
        proximityTone = null
        super.onDestroy()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            methodChannel?.invokeMethod("volumeUpPressed", null)
            return true // Prevenir que suba el volumen del sistema
        }
        return super.onKeyDown(keyCode, event)
    }
}
