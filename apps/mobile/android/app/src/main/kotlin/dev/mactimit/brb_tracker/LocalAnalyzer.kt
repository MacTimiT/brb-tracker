package dev.mactimit.brb_tracker

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.CancellationException

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
            val detector = BreakDetector()
            var timestamp = 0.0
            var consecutiveFailures = 0
            while (timestamp < duration) {
                if (cancelled()) throw CancellationException("Analysis cancelled")
                val micros = (timestamp * 1_000_000).toLong()
                val bitmap = if (Build.VERSION.SDK_INT >= 27) decoder.getScaledFrameAtTime(micros, MediaMetadataRetriever.OPTION_CLOSEST, width, height)
                    else decoder.getFrameAtTime(micros, MediaMetadataRetriever.OPTION_CLOSEST)
                if (bitmap == null) {
                    failedFrames++
                    consecutiveFailures++
                    check(consecutiveFailures < 3) { "Android could not decode consecutive video frames; try a different MP4 file" }
                    // A decode failure is not evidence the BRB screen disappeared.
                } else {
                    consecutiveFailures = 0
                    try {
                        detector.sample(timestamp, ocr.isBrb(bitmap, profile))
                        decoded++
                    } finally { bitmap.recycle() }
                }
                progress(timestamp / duration)
                timestamp += interval
            }
            check(decoded > 0) { "No video frames could be decoded" }
            val breaks = detector.finish(duration).map { item ->
                val (reason, evidence) = Detection.reason(cues, item.start)
                JSONObject().put("start_seconds", item.start).put("end_seconds", item.end)
                    .put("reason", reason).put("suggested_reason", reason).put("evidence", evidence)
                    .put("confidence", if (reason == "Unknown") "unknown" else "keyword")
                    .put("reviewed", false).put("truncated", item.truncated)
            }
            val warnings = mutableListOf("Analyzed on Android every ${interval}s. Boundaries are estimates; short screens and OCR failures can be missed.")
            if (profile == "gamin4hope") warnings.add("Gamin4Hope profile: OCR checks red banner text in the bottom-left region, excluding the right-side chat. Other layouts can be missed.")
            if (cues.isEmpty()) warnings.add("No usable transcript. Reasons are Unknown until manually reviewed; local speech transcription is not included.")
            if (failedFrames > 0) warnings.add("Android could not decode $failedFrames sampled frames; inspect break boundaries.")
            val sourceUrl = input.optString("url")
            val videoId = runCatching { Detection.videoId(sourceUrl) }.getOrNull()
            return JSONObject().put("schema_version", 1).put("id", id).put("title", input.optString("title", "Local VOD"))
                .put("streamer", "Gamin4Hope").put("source_url", sourceUrl).put("video_id", videoId ?: JSONObject.NULL)
                .put("duration_seconds", duration).put("sample_interval_seconds", interval)
                .put("transcript_source", if (cues.isEmpty()) "none" else "android-captions")
                .put("detector_profile", profile)
                .put("is_demo", false).put("warnings", JSONArray(warnings)).put("breaks", JSONArray(breaks))
        } finally { screenOcr?.close(); decoder.release() }
    }
}
