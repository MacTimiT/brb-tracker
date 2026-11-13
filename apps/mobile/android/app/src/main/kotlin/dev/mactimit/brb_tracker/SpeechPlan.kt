package dev.mactimit.brb_tracker

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.json.JSONObject

data class AudioWindow(val start: Double, val end: Double)
data class SpeechWord(val start: Double, val end: Double, val text: String)

/** Decode only speech that could affect a detected break's reason. */
object SpeechPlan {
    fun windows(breakStarts: List<Double>, lookback: Double = 60.0): List<AudioWindow> {
        require(lookback.isFinite() && lookback > 0)
        val result = mutableListOf<AudioWindow>()
        breakStarts.sorted().forEach { end ->
            require(end.isFinite() && end >= 0)
            val start = maxOf(0.0, end - lookback)
            if (start == end) return@forEach
            val last = result.lastOrNull()
            if (last != null && start <= last.end) {
                result[result.lastIndex] = AudioWindow(last.start, maxOf(last.end, end))
            } else result.add(AudioWindow(start, end))
        }
        return result
    }

    fun parseWords(json: String, offset: Double): List<SpeechWord> {
        val array = JSONObject(json).optJSONArray("result") ?: return emptyList()
        return (0 until array.length()).mapNotNull { index ->
            val item = array.getJSONObject(index)
            val text = item.optString("word").trim()
            if (text.isEmpty()) null else SpeechWord(offset + item.getDouble("start"), offset + item.getDouble("end"), text)
        }
    }

    fun cues(words: List<SpeechWord>, breakStarts: List<Double>): List<Cue> {
        val result = mutableListOf<Cue>()
        val group = mutableListOf<SpeechWord>()
        fun flush() {
            if (group.isNotEmpty()) result.add(Cue(group.first().start, group.last().end, group.joinToString(" ") { it.text }))
            group.clear()
        }
        words.sortedBy { it.start }.forEach { word ->
            if (group.isNotEmpty() && (word.start - group.last().end > 1.0 || word.end - group.first().start > 8.0 ||
                        breakStarts.any { it >= group.first().start && it < word.end })) flush()
            group.add(word)
        }
        flush()
        return result
    }
}

/** Average downsampling to the 16 kHz mono PCM expected by the English model. */
class Pcm16Resampler(private val inputRate: Int, private val channels: Int) {
    init {
        require(inputRate in 8_000..192_000 && channels in 1..8)
    }
    private var phase = 0
    private var sum = 0L
    private var count = 0

    fun convert(input: ByteBuffer): ByteArray {
        input.order(ByteOrder.LITTLE_ENDIAN)
        val out = ByteArrayOutputStream(input.remaining() * 16_000 / inputRate / channels + 4)
        while (input.remaining() >= channels * 2) {
            var mono = 0L
            repeat(channels) { mono += input.short.toLong() }
            mono /= channels
            sum += mono
            count++
            phase += 16_000
            while (phase >= inputRate) {
                val sample = (if (count > 0) sum / count else mono).toInt().coerceIn(-32768, 32767)
                out.write(sample and 255)
                out.write((sample ushr 8) and 255)
                phase -= inputRate
                sum = 0
                count = 0
            }
        }
        return out.toByteArray()
    }
}
