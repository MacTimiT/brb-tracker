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
    @Test fun bundledDownloaderRunsOnAndroid() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        YoutubeDL.init(context)
        FFmpeg.init(context)
        val output = YoutubeDL.execute(YoutubeDLRequest(emptyList<String>()).addOption("--version"), "version-test", null).out
        assertTrue("Bundled Python and yt-dlp did not run: $output", Regex("20\\d{2}\\.\\d{2}\\.\\d{2}").containsMatchIn(output))
    }

    @Test fun foregroundServiceDecodesOcrClassifiesAndPersistsWithoutServer() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val video = File(context.cacheDir, "synthetic-test.mp4")
        val transcript = File(context.cacheDir, "synthetic-test.json")
        instrumentation.context.assets.open("synthetic.mp4").use { source -> video.outputStream().use { source.copyTo(it) } }
        transcript.writeText("""[{"start":2,"end":4,"text":"I need to pee. Be right back."},{"start":16,"end":18,"text":"I'm going to grab a snack."}]""")
        ActivityScenario.launch(MainActivity::class.java).use {
            instrumentation.waitForIdleSync()
            val input = JSONObject().put("video_uri", Uri.fromFile(video).toString()).put("transcript_uri", Uri.fromFile(transcript).toString())
                .put("url", "").put("interval", 2.0).put("title", "Generated Android OCR test")
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
