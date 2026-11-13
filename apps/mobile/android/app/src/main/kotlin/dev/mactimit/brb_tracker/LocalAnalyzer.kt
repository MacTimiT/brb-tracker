package dev.mactimit.brb_tracker

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CancellationException
import java.time.Instant

class LocalAnalyzer(private val context: Context) {
    fun analyze(uri: Uri, input: JSONObject, id: String, cues: List<Cue>, cancelled: () -> Boolean, progress: (Double) -> Unit): JSONObject {
        val interval = input.optDouble("interval", 2.0)
        require(interval.isFinite() && interval in 1.0..30.0)
        val profile = input.optString("detector_profile", "gamin4hope")
        require(profile in BannerProfile.names) { "Unknown detector profile" }
        val decoder = MediaMetadataRetriever()
        var screenOcr: ScreenOcr? = null
        var decoded = 0
        var failedFrames = 0
        try {
            val ocr = ScreenOcr(context)
            screenOcr = ocr
            decoder.setDataSource(context, uri)
            val duration = decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toDouble() / 1000
            require(duration.isFinite() && duration > 0) { "The video has no usable duration" }
            val originalWidth = decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt() ?: 960
            val originalHeight = decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt() ?: 540
            val width = minOf(originalWidth, 960)
            val height = maxOf(1, (originalHeight.toDouble() * width / originalWidth).toInt())
            val adaptive = input.optBoolean("adaptive_scan", false)
            val samples = sortedMapOf<Double, Boolean?>()
            var consecutiveFailures = 0
            fun sample(timestamp: Double): Boolean? {
                if (cancelled()) throw CancellationException("Analysis cancelled")
                val micros = (timestamp * 1_000_000).toLong()
                val bitmap = if (Build.VERSION.SDK_INT >= 27) decoder.getScaledFrameAtTime(micros, MediaMetadataRetriever.OPTION_CLOSEST, width, height)
                    else decoder.getFrameAtTime(micros, MediaMetadataRetriever.OPTION_CLOSEST)
                if (bitmap == null) {
                    failedFrames++
                    consecutiveFailures++
                    check(consecutiveFailures < 3) { "Android could not decode consecutive video frames; try a different MP4 file" }
                    return null // Unknown is never evidence the screen disappeared.
                } else {
                    consecutiveFailures = 0
                    try {
                        decoded++
                        return ocr.isBrb(bitmap, profile)
                    } finally { bitmap.recycle() }
                }
            }
            var previousCoarse: Pair<Double, Boolean?>? = null
            fun scanAt(time: Double) {
                val present = sample(time)
                if (adaptive) {
                    previousCoarse?.let { (lastTime, lastPresent) ->
                        // Refine while the decoder is still near this span. A
                        // second pass from the end would seek across the VOD.
                        ScanPlan.refine(mapOf(lastTime to lastPresent, time to present))
                            .forEach { samples[it] = sample(it) }
                    }
                }
                samples[time] = present
                previousCoarse = time to present
                progress(time / duration * 0.99)
            }
            var timestamp = 0.0
            while (timestamp < duration) {
                scanAt(timestamp)
                timestamp += interval
            }
            if (adaptive) {
                // Include the tail so an exit in the final coarse interval can be refined.
                val tail = maxOf(0.0, duration - 0.001)
                if (tail > (previousCoarse?.first ?: -1.0) && !samples.containsKey(tail)) scanAt(tail)
            }
            val detector = BreakDetector()
            samples.forEach { (time, present) -> if (present != null) detector.sample(time, present) }
            check(decoded > 0) { "No video frames could be decoded" }
            val breaks = detector.finish(duration).map { item ->
                val (reason, evidence) = Detection.reason(cues, item.start)
                JSONObject().put("start_seconds", item.start).put("end_seconds", item.end)
                    .put("reason", reason).put("suggested_reason", reason).put("evidence", evidence)
                    .put("confidence", if (reason == "Unknown") "unknown" else "keyword")
                    .put("reviewed", false).put("truncated", item.truncated)
            }
            val warnings = mutableListOf("Sampled every ${interval}s${if (adaptive) " with 1s transition refinement" else ""}. Short screens between samples can be missed.")
            if (profile == "gamin4hope") warnings.add("Gamin4Hope profile: OCR checks red banner text in the bottom-left region, excluding the right-side chat. Other layouts can be missed.")
            if (cues.isEmpty()) warnings.add("No usable transcript. Reasons are Unknown until manually reviewed.")
            if (failedFrames > 0) warnings.add("Android could not decode $failedFrames sampled frames; inspect break boundaries.")
            val sourceUrl = input.optString("url")
            val videoId = runCatching { Detection.videoId(sourceUrl) }.getOrNull()
            return JSONObject().put("schema_version", 1).put("id", id).put("title", input.optString("title", "Local VOD"))
                .put("streamer", "Gamin4Hope").put("source_url", sourceUrl).put("video_id", videoId ?: JSONObject.NULL)
                .put("duration_seconds", duration).put("sample_interval_seconds", interval)
                .put("vod_date", input.opt("vod_date") ?: JSONObject.NULL).put("vod_date_source", input.optString("vod_date_source", "unknown"))
                .put("stream_started_at", input.opt("stream_started_at") ?: JSONObject.NULL).put("analyzed_at", Instant.now().toString())
                .put("adaptive_scan", adaptive).put("boundary_refinement_seconds", if (adaptive) 1 else JSONObject.NULL)
                .put("frames_checked", decoded).put("ocr_calls", ocr.calls).put("banner_cache_hits", ocr.cacheHits)
                .put("transcript_source", if (cues.isEmpty()) "none" else input.optString("transcript_source", "imported"))
                .put("detector_profile", profile)
                .put("is_demo", false).put("warnings", JSONArray(warnings)).put("breaks", JSONArray(breaks))
        } finally { screenOcr?.close(); decoder.release() }
    }
}
