package dev.mactimit.brb_tracker

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import org.vosk.Model
import org.vosk.Recognizer
import java.util.concurrent.CancellationException

/** Decodes only the audio windows that precede detected breaks. */
class SpeechTranscriber(private val context: Context) {
    fun transcribe(uri: Uri, breakStarts: List<Double>, cancelled: () -> Boolean,
                   modelProgress: (Double) -> Unit, speechProgress: (Double) -> Unit): List<Cue> {
        val windows = SpeechPlan.windows(breakStarts)
        if (windows.isEmpty()) return emptyList()
        val probe = MediaExtractor()
        try {
            probe.setDataSource(context, uri, null)
            check((0 until probe.trackCount).any {
                probe.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            }) { "This video has no audio track to transcribe" }
        } finally { probe.release() }
        val modelPath = SpeechModelStore(context).get(cancelled, modelProgress)
        val words = mutableListOf<SpeechWord>()
        Model(modelPath.absolutePath).use { model ->
            modelProgress(1.0)
            speechProgress(0.0)
            val total = windows.sumOf { it.end - it.start }
            var done = 0.0
            windows.forEach { window ->
                if (cancelled()) throw CancellationException()
                decodeWindow(uri, window, model, cancelled,
                    { position -> speechProgress((done + position * (window.end - window.start)) / total) },
                    { json, offset -> words.addAll(SpeechPlan.parseWords(json, offset)) })
                done += window.end - window.start
                speechProgress(done / total)
            }
        }
        return SpeechPlan.cues(words, breakStarts)
    }

    private fun decodeWindow(uri: Uri, window: AudioWindow, model: Model, cancelled: () -> Boolean,
                             progress: (Double) -> Unit, result: (String, Double) -> Unit) {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(context, uri, null)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: error("This video has no audio track to transcribe")
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: error("Audio format is missing")
            extractor.selectTrack(track)
            extractor.seekTo((window.start * 1_000_000).toLong(), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()
            var inputEnded = false
            var outputEnded = false
            var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var resampler = Pcm16Resampler(sampleRate, channels)
            var audioStart = window.start
            var receivedAudio = false
            Recognizer(model, 16_000f).use { recognizer ->
                recognizer.setWords(true)
                val info = MediaCodec.BufferInfo()
                while (!outputEnded) {
                    if (cancelled()) throw CancellationException()
                    if (!inputEnded) {
                        val index = codec.dequeueInputBuffer(10_000)
                        if (index >= 0) {
                            val buffer = codec.getInputBuffer(index) ?: error("Audio decoder input is unavailable")
                            buffer.clear()
                            val timestamp = extractor.sampleTime
                            val count = if (timestamp < 0 || timestamp >= window.end * 1_000_000) -1 else extractor.readSampleData(buffer, 0)
                            if (count < 0) {
                                codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputEnded = true
                            } else {
                                codec.queueInputBuffer(index, 0, count, timestamp, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val index = codec.dequeueOutputBuffer(info, 10_000)
                    when (index) {
                        MediaCodec.INFO_TRY_AGAIN_LATER, MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
                        MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val outputFormat = codec.outputFormat
                            val encoding = if (outputFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) outputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING) else 2
                            check(encoding == 2) { "Unsupported decoded audio sample format" }
                            sampleRate = outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            channels = outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            resampler = Pcm16Resampler(sampleRate, channels)
                        }
                        in 0..Int.MAX_VALUE -> {
                            if (info.size > 0) {
                                val buffer = codec.getOutputBuffer(index) ?: error("Audio decoder output is unavailable")
                                val bytesPerFrame = channels * 2
                                val frames = info.size / bytesPerFrame
                                val begin = (((window.start * 1_000_000 - info.presentationTimeUs) * sampleRate) / 1_000_000).toInt().coerceIn(0, frames)
                                val end = (((window.end * 1_000_000 - info.presentationTimeUs) * sampleRate) / 1_000_000).toInt().coerceIn(0, frames)
                                if (end > begin) {
                                    if (!receivedAudio) {
                                        audioStart = info.presentationTimeUs / 1_000_000.0 + begin.toDouble() / sampleRate
                                        receivedAudio = true
                                    }
                                    buffer.position(info.offset + begin * bytesPerFrame)
                                    buffer.limit(info.offset + end * bytesPerFrame)
                                    val pcm = resampler.convert(buffer)
                                    if (pcm.isNotEmpty() && recognizer.acceptWaveForm(pcm, pcm.size)) result(recognizer.getResult(), audioStart)
                                    progress(((info.presentationTimeUs / 1_000_000.0 + end.toDouble() / sampleRate - window.start) /
                                        (window.end - window.start)).coerceIn(0.0, 0.99))
                                }
                            }
                            outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            codec.releaseOutputBuffer(index, false)
                        }
                    }
                }
                result(recognizer.getFinalResult(), audioStart)
            }
        } finally {
            runCatching { codec?.stop() }
            codec?.release()
            extractor.release()
        }
    }

}
