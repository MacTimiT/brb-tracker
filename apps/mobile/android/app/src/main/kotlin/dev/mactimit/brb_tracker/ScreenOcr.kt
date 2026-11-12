package dev.mactimit.brb_tracker

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Paint
import android.graphics.Rect
import android.util.AtomicFile
import com.googlecode.tesseract.android.TessBaseAPI
import java.io.Closeable
import java.io.File

class ScreenOcr(context: Context) : Closeable {
    private val tess = TessBaseAPI()
    private val cache = BannerCache()
    var calls = 0
        private set
    val cacheHits: Int get() = cache.hits
    init {
        try {
            val root = File(context.noBackupFilesDir, "tesseract")
            val model = File(root, "tessdata/eng.traineddata")
            if (model.length() != 4_113_088L) {
                model.parentFile!!.mkdirs()
                val atomic = AtomicFile(model)
                val output = atomic.startWrite()
                try {
                    context.assets.open("tessdata/eng.traineddata").use { it.copyTo(output) }
                    atomic.finishWrite(output)
                } catch (e: Exception) { atomic.failWrite(output); throw e }
            }
            check(tess.init(root.absolutePath, "eng")) { "Could not initialize the bundled OCR model" }
            tess.pageSegMode = TessBaseAPI.PageSegMode.PSM_SPARSE_TEXT
        } catch (e: Exception) { tess.recycle(); throw e }
    }
    fun isBrb(frame: Bitmap, profile: String): Boolean {
        require(profile in BannerProfile.names) { "Unknown detector profile" }
        val prepared = if (profile == "gamin4hope") redBanner(frame) else grayscale(frame)
        if (prepared == null) return false
        return try {
            val read = {
                calls++
                tess.setImage(prepared)
                Detection.isBrb(tess.utF8Text.orEmpty())
            }
            if (profile == "gamin4hope") {
                val pixels = IntArray(prepared.width * prepared.height)
                prepared.getPixels(pixels, 0, prepared.width, 0, 0, prepared.width, prepared.height)
                cache.recognize(pixels, prepared.width, read)
            } else read()
        } finally { tess.clear(); prepared.recycle() }
    }
    private fun grayscale(frame: Bitmap): Bitmap {
        val width = minOf(frame.width, 960)
        val height = maxOf(1, frame.height * width / frame.width)
        val gray = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val paint = Paint().apply { colorFilter = ColorMatrixColorFilter(ColorMatrix().apply { setSaturation(0f) }) }
        Canvas(gray).drawBitmap(frame, null, Rect(0, 0, width, height), paint)
        return gray
    }
    private fun redBanner(frame: Bitmap): Bitmap? {
        val bounds = BannerProfile.bounds(frame.width, frame.height)
        val crop = Bitmap.createBitmap(frame, bounds[0], bounds[1], bounds[2] - bounds[0], bounds[3] - bounds[1])
        val height = maxOf(1, (crop.height.toDouble() * 960 / crop.width).toInt())
        val resized = Bitmap.createScaledBitmap(crop, 960, height, true)
        try {
            val pixels = IntArray(resized.width * resized.height)
            resized.getPixels(pixels, 0, resized.width, 0, 0, resized.width, resized.height)
            var redCount = 0
            for (index in pixels.indices) {
                val color = pixels[index]
                val red = BannerProfile.isRed((color shr 16) and 255, (color shr 8) and 255, color and 255)
                if (red) redCount++
                pixels[index] = if (red) android.graphics.Color.BLACK else android.graphics.Color.WHITE
            }
            if (redCount < maxOf(12, (pixels.size * 0.001).toInt())) return null
            return Bitmap.createBitmap(pixels, resized.width, resized.height, Bitmap.Config.ARGB_8888)
        } finally {
            if (resized !== crop && resized !== frame) resized.recycle()
            if (crop !== frame) crop.recycle()
        }
    }
    override fun close() { tess.recycle() }
}
