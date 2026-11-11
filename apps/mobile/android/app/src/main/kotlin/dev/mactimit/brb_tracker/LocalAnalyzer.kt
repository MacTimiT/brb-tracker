package dev.mactimit.brb_tracker

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import com.googlecode.tesseract.android.TessBaseAPI
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.CancellationException

class LocalAnalyzer(private val context: Context) {
    fun analyze(uri: Uri, input: JSONObject, id: String, cues: List<Cue>, cancelled: () -> Boolean, progress: (Double) -> Unit): JSONObject {
        val interval = input.optDouble("interval", 2.0)
        require(interval.isFinite() && interval in 1.0..30.0)
        val tessRoot = File(context.noBackupFilesDir, "tesseract")
        val model = File(tessRoot, "tessdata/eng.traineddata")
        if (!model.exists()) {
            model.parentFile!!.mkdirs()
            context.assets.open("tessdata/eng.traineddata").use { source -> model.outputStream().use { source.copyTo(it) } }
        }
        val decoder = MediaMetadataRetriever()
        val tess = TessBaseAPI()
        var decoded = 0
        var failedFrames = 0
        try {
            decoder.setDataSource(context, uri)
            val duration = decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toDouble() / 1000
            require(duration.isFinite() && duration > 0) { "The video has no usable duration" }
            val originalWidth = decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toInt() ?: 960
            val originalHeight = decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toInt() ?: 540
            val width = minOf(originalWidth, 960)
            val height = maxOf(1, (originalHeight.toDouble() * width / originalWidth).toInt())
            check(tess.init(tessRoot.absolutePath, "eng")) { "Could not initialize the bundled OCR model" }
            tess.pageSegMode = TessBaseAPI.PageSegMode.PSM_SPARSE_TEXT
            val detector = BreakDetector()
            val paint = Paint().apply { colorFilter = ColorMatrixColorFilter(ColorMatrix().apply { setSaturation(0f) }) }
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
                    val gray = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    try {
                        Canvas(gray).drawBitmap(bitmap, null, android.graphics.Rect(0, 0, width, height), paint)
                        tess.setImage(gray)
                        detector.sample(timestamp, Detection.isBrb(tess.utF8Text.orEmpty()))
                        tess.clear()
                        decoded++
                    } finally { gray.recycle(); bitmap.recycle() }
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
            if (cues.isEmpty()) warnings.add("No usable transcript. Reasons are Unknown until manually reviewed; local speech transcription is not included.")
            if (failedFrames > 0) warnings.add("Android could not decode $failedFrames sampled frames; inspect break boundaries.")
            val sourceUrl = input.optString("url")
            val videoId = runCatching { Detection.videoId(sourceUrl) }.getOrNull()
            return JSONObject().put("schema_version", 1).put("id", id).put("title", input.optString("title", "Local VOD"))
                .put("streamer", "Gamin4Hope").put("source_url", sourceUrl).put("video_id", videoId ?: JSONObject.NULL)
                .put("duration_seconds", duration).put("sample_interval_seconds", interval)
                .put("transcript_source", if (cues.isEmpty()) "none" else "android-captions")
                .put("is_demo", false).put("warnings", JSONArray(warnings)).put("breaks", JSONArray(breaks))
        } finally { tess.recycle(); decoder.release() }
    }
}
