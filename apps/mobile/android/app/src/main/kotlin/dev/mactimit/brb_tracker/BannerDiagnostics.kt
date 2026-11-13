package dev.mactimit.brb_tracker

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject

/** Local, temporary OCR inspection; no screenshot is added to a public report. */
class BannerDiagnostics(private val context: Context) {
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
