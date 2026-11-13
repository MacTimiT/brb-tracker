package dev.mactimit.brb_tracker

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.media.MediaMetadataRetriever
import android.os.Build
import java.io.ByteArrayOutputStream
import org.json.JSONArray
import org.json.JSONObject

/** Local, temporary OCR inspection; no screenshot is added to a public report. */
class BannerDiagnostics(private val context: Context) {
    fun inspectVideo(uri: Uri, seconds: Double): JSONObject {
        val decoder = MediaMetadataRetriever()
        try {
            decoder.setDataSource(context, uri)
            val duration = decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toDouble() / 1000
            require(seconds.isFinite() && seconds >= 0 && seconds < duration) { "Choose a timestamp inside the VOD" }
            val width = minOf(decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)!!.toInt(), 960)
            val sourceWidth = decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)!!.toInt()
            val sourceHeight = decoder.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)!!.toInt()
            val height = maxOf(1, sourceHeight * width / sourceWidth)
            val micros = (seconds * 1_000_000).toLong()
            val frame = if (Build.VERSION.SDK_INT >= 27) decoder.getScaledFrameAtTime(micros, MediaMetadataRetriever.OPTION_CLOSEST, width, height)
                else decoder.getFrameAtTime(micros, MediaMetadataRetriever.OPTION_CLOSEST)
            checkNotNull(frame) { "Android could not decode the requested frame" }
            try {
                val check = ScreenOcr(context).use { it.diagnose(frame) }
                val output = ByteArrayOutputStream()
                frame.compress(Bitmap.CompressFormat.PNG, 100, output)
                return JSONObject().put("source_kind", "video-frame").put("timestamp_seconds", seconds)
                    .put("duration_seconds", duration).put("source_width", sourceWidth).put("source_height", sourceHeight)
                    .put("frame", android.util.Base64.encodeToString(output.toByteArray(), android.util.Base64.NO_WRAP))
                    .put("checks", JSONArray().put(check))
            } finally { frame.recycle() }
        } finally { decoder.release() }
    }
    fun inspect(uri: Uri): JSONObject {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Choose a readable BRB screenshot" }
        val options = BitmapFactory.Options().apply { inSampleSize = 1 }
        while (maxOf(bounds.outWidth, bounds.outHeight) / options.inSampleSize > 2048) options.inSampleSize *= 2
        val original = context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
            ?: error("Could not open the screenshot")
        try {
            val checks = JSONArray()
            ScreenOcr(context).use { ocr ->
                for (width in listOf(original.width, 640).distinct()) {
                    val scaled = Bitmap.createScaledBitmap(original, width, maxOf(1, original.height * width / original.width), true)
                    try { checks.put(ocr.diagnose(scaled)) }
                    finally { if (scaled !== original) scaled.recycle() }
                }
            }
            return JSONObject().put("checks", checks)
        } finally { original.recycle() }
    }
}
