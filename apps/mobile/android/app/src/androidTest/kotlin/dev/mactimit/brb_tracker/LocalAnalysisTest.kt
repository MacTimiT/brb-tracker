package dev.mactimit.brb_tracker

import android.net.Uri
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import com.yausername.ffmpeg.FFmpeg
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class LocalAnalysisTest {
    @Test fun bannerProfileRecognizesRedBannerAndRejectsChatOnlyPhrase() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        ScreenOcr(instrumentation.targetContext).use { ocr ->
            for ((name, expected) in listOf("banner.png" to true, "chat-only.png" to false)) {
                val bitmap = checkNotNull(instrumentation.context.assets.open(name).use { android.graphics.BitmapFactory.decodeStream(it) }) { "Could not decode test fixture $name" }
                try {
                    assertEquals(name, expected, ocr.isBrb(bitmap, "gamin4hope"))
                    if (expected) {
                        val calls = ocr.calls
                        assertTrue(ocr.isBrb(bitmap, "gamin4hope"))
                        assertEquals(calls, ocr.calls)
                        assertTrue(ocr.cacheHits > 0)
                    }
                }
                finally { bitmap.recycle() }
            }
        }
    }
    @Test fun bundledDownloaderRunsOnAndroid() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        YoutubeDL.init(context)
        FFmpeg.init(context)
        val output = YoutubeDL.execute(YoutubeDLRequest(emptyList<String>()).addOption("--version"), "version-test", null).out
        assertTrue("Bundled Python and yt-dlp did not run: $output", Regex("20\\d{2}\\.\\d{2}\\.\\d{2}").containsMatchIn(output))
    }

    @Test fun bannerSurvivesVideoDownloadResolutionsWithoutMatchingChat() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        ScreenOcr(instrumentation.targetContext).use { ocr ->
            for ((name, expected) in listOf("banner.png" to true, "chat-only.png" to false)) {
                val original = instrumentation.context.assets.open(name).use { android.graphics.BitmapFactory.decodeStream(it) }!!
                try {
                    for (width in listOf(854, 640, 480, 360)) {
                        val resized = android.graphics.Bitmap.createScaledBitmap(original, width, maxOf(1, original.height * width / original.width), true)
                        try {
                            assertEquals("$name at width $width", expected, ocr.isBrb(resized, "gamin4hope"))
                            if (width == 640 && expected) {
                                val diagnostic = ocr.diagnose(resized)
                                assertTrue(diagnostic.getBoolean("matched"))
                                assertTrue(diagnostic.getJSONArray("texts").length() > 0)
                                assertTrue(diagnostic.getString("mask").isNotEmpty())
                            }
                        }
                        finally { if (resized !== original) resized.recycle() }
                    }
                } finally { original.recycle() }
            }
        }
    }

    @Test fun foregroundServiceDecodesOcrClassifiesAndPersistsWithoutServer() = scan(false)
    @Test fun fastScanRefinesEdgesAndPreservesHistoricalDateAndReasons() = scan(true)

    @Test fun timestampProbeDecodesRequestedFrameAndKeepsImagesOutOfJobList() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val video = File(context.cacheDir, "probe-test.mp4")
        instrumentation.context.assets.open("synthetic.mp4").use { source -> video.outputStream().use { source.copyTo(it) } }
        ActivityScenario.launch(MainActivity::class.java).use {
            instrumentation.waitForIdleSync()
            val store = JobStore(context)
            val id = AnalysisService.launch(context, JSONObject().put("video_uri", Uri.fromFile(video).toString())
                .put("probe_seconds", 8.0).put("title", "Generated frame probe")).getString("id")
            try {
                val deadline = System.currentTimeMillis() + 30_000
                while (store.get(id).getString("status") in setOf("queued", "running") && System.currentTimeMillis() < deadline) Thread.sleep(100)
                val job = store.get(id)
                assertEquals(job.toString(), "completed", job.getString("status"))
                assertFalse(job.has("report"))
                val diagnostic = job.getJSONObject("diagnostic")
                assertEquals(8.0, diagnostic.getDouble("timestamp_seconds"), 0.001)
                val bytes = android.util.Base64.decode(diagnostic.getString("frame"), android.util.Base64.DEFAULT)
                val bitmap = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)!!
                try { ScreenOcr(context).use { ocr -> assertTrue(ocr.isBrb(bitmap, "full_frame")) } }
                finally { bitmap.recycle() }
                val jobs = store.list()
                val summary = (0 until jobs.length()).map { jobs.getJSONObject(it) }.first { it.getString("id") == id }
                assertFalse(summary.has("diagnostic"))
            } finally { store.delete(id); video.delete() }
        }
    }

    private fun scan(adaptive: Boolean) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val video = File(context.cacheDir, "synthetic-test.mp4")
        val transcript = File(context.cacheDir, "synthetic-test.json")
        instrumentation.context.assets.open("synthetic.mp4").use { source -> video.outputStream().use { source.copyTo(it) } }
        transcript.writeText("""[{"start":2,"end":4,"text":"I need to pee. Be right back."},{"start":16,"end":18,"text":"I'm going to grab a snack."}]""")
        ActivityScenario.launch(MainActivity::class.java).use {
            instrumentation.waitForIdleSync()
            val input = JSONObject().put("video_uri", Uri.fromFile(video).toString()).put("transcript_uri", Uri.fromFile(transcript).toString())
                .put("vod_date", "2026-10-22").put("vod_date_source", "release_date").put("adaptive_scan", adaptive)
                .put("url", "").put("interval", if (adaptive) 5.0 else 2.0).put("detector_profile", "full_frame").put("title", "Generated Android OCR test")
            val job = AnalysisService.launch(context, input)
            val id = job.getString("id")
            val store = JobStore(context)
            try {
                val deadline = System.currentTimeMillis() + 120_000
                while (store.get(id).getString("status") in setOf("queued", "running") && System.currentTimeMillis() < deadline) Thread.sleep(250)
                val completed = store.get(id)
                assertEquals("Native analysis failed: $completed", "completed", completed.getString("status"))
                val report = completed.getJSONObject("report")
                assertFalse(report.getBoolean("is_demo"))
                assertEquals("2026-10-22", report.getString("vod_date"))
                assertEquals("imported", report.getString("transcript_source"))
                assertTrue(report.has("analyzed_at"))
                assertEquals(adaptive, report.getBoolean("adaptive_scan"))
                val breaks = report.getJSONArray("breaks")
                assertEquals(2, breaks.length())
                assertEquals(6.0, breaks.getJSONObject(0).getDouble("start_seconds"), 2.0)
                assertEquals(14.0, breaks.getJSONObject(0).getDouble("end_seconds"), 2.0)
                assertEquals("Pee", breaks.getJSONObject(0).getString("reason"))
                assertEquals("Snack", breaks.getJSONObject(1).getString("reason"))
                assertTrue(breaks.getJSONObject(1).getBoolean("truncated"))
                store.review(id, 0, "Other")
                val restored = JobStore(context).get(id).getJSONObject("report").getJSONArray("breaks").getJSONObject(0)
                assertEquals("Other", restored.getString("reason"))
                assertEquals("Pee", restored.getString("suggested_reason"))
                assertTrue(restored.getBoolean("reviewed"))
            } finally {
                if (AnalysisService.activeId == id) AnalysisService.cancel(context, id)
                store.delete(id)
                video.delete(); transcript.delete()
            }
        }
    }
}
