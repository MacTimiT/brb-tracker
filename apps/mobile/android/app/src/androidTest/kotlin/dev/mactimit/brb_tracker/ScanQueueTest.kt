package dev.mactimit.brb_tracker

import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.time.Instant

@RunWith(AndroidJUnit4::class)
class ScanQueueTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val store = JobStore(context)
    private val media = VodFiles(context)

    private fun fixture(destination: File) {
        destination.parentFile?.mkdirs()
        instrumentation.context.assets.open("synthetic.mp4").use { source ->
            destination.outputStream().use { source.copyTo(it) }
        }
    }

    private fun input(id: String) = JSONObject()
        .put("url", "https://www.youtube.com/watch?v=$id")
        .put("interval", 2.0)
        .put("detector_profile", "full_frame")
        .put("speech_fallback", false)

    private fun awaitFinished(id: String): JSONObject {
        val deadline = System.currentTimeMillis() + 120_000
        while (System.currentTimeMillis() < deadline) {
            val job = store.get(id)
            if (job.getString("status") !in setOf("queued", "running")) return job
            Thread.sleep(100)
        }
        fail("Scan $id did not finish: ${store.get(id)}")
        return store.get(id)
    }

    @Test fun pendingScansResumeInOrderAndReuseRetainedVideoOffline() {
        val original = store.create(input("queuevideo1")).getString("id")
        store.update(original) { it.put("status", "failed") }
        val firstVideo = media.video(original).also(::fixture)
        val first = store.create(store.rescanInput(original, JSONObject())).getString("id")
        val secondVideo = File(context.cacheDir, "queue-second.mp4").also(::fixture)
        val second = store.create(input("queuevideo2").put("video_uri", Uri.fromFile(secondVideo).toString()))
            .getString("id")
        try {
            assertEquals(first, store.queuedId())
            assertEquals(firstVideo, store.video(first))
            val activeDelete = runCatching { store.removeVideo(original) }
            assertTrue(activeDelete.isFailure)
            store.recoverInterrupted()
            assertEquals(first, store.queuedId())

            ActivityScenario.launch(MainActivity::class.java).use {
                val firstResult = awaitFinished(first)
                val secondResult = awaitFinished(second)
                assertEquals(firstResult.toString(), "completed", firstResult.getString("status"))
                assertEquals(secondResult.toString(), "completed", secondResult.getString("status"))
                val report = firstResult.getJSONObject("report")
                assertTrue(report.getJSONArray("breaks").length() > 0)
                assertFalse(Instant.parse(secondResult.getJSONObject("report").getString("analyzed_at"))
                    .isBefore(Instant.parse(report.getString("analyzed_at"))))

                val timings = report.getJSONObject("timings_ms")
                assertTrue(timings.getLong("total") >= timings.getLong("decode") + timings.getLong("ocr"))
                assertFalse(timings.has("download"))
                store.review(first, 0, "Help Rachel", listOf("Drink", "Mental Break"))
                store.removeVideo(original)
                assertFalse(firstVideo.exists())
                val row = store.list().let { rows ->
                    (0 until rows.length()).map(rows::getJSONObject).first { it.getString("id") == first }
                }
                assertEquals("queuevideo1", row.getString("completed_video_id"))
                assertFalse(row.getBoolean("has_video"))
                val reviewed = store.get(first).getJSONObject("report").getJSONArray("breaks").getJSONObject(0)
                assertEquals("Help Rachel", reviewed.getString("reason"))
                assertEquals("Drink", reviewed.getJSONArray("additional_reasons").getString(0))
            }
        } finally {
            for (id in listOf(first, second, original)) {
                if (store.get(id).optString("status") == "queued") store.cancelQueued(id)
                if (store.get(id).optString("status") != "running") store.delete(id)
            }
            secondVideo.delete()
        }
    }

    @Test fun interruptedScanKeepsItsLastStepAndCanBeRetried() {
        val id = store.create(input("queuevideo9")).getString("id")
        try {
            store.update(id) { it.put("status", "running").put("stage", JobPhase.METADATA.label) }
            store.recoverInterrupted()
            val recovered = store.get(id)
            assertEquals("failed", recovered.getString("status"))
            assertTrue(recovered.getString("error").contains(JobPhase.METADATA.label))
            assertEquals(1, store.retryFailed(id))
            assertFalse(store.get(id).has("error"))
        } finally {
            store.cancelQueued(id)
            store.delete(id)
        }
    }

    @Test fun reorderAndRetryPersistAndBulkDeletionSkipsQueuedMedia() {
        val first = store.create(input("queuevideo3")).getString("id")
        val second = store.create(input("queuevideo4")).getString("id")
        val failed = store.create(input("queuevideo5")).getString("id")
        val completed = store.create(input("queuevideo6")).getString("id")
        try {
            store.update(failed) { it.put("status", "failed").put("error", "Temporary error") }
            store.update(completed) { it.put("status", "completed") }
            val inUse = media.video(failed).also(::fixture)
            val unused = media.video(completed).also(::fixture)
            assertEquals(1, store.retryFailed())
            assertEquals(first, store.queuedId())
            store.moveUp(second)
            assertEquals(second, JobStore(context).queuedId())
            val retry = store.get(failed)
            assertFalse(retry.has("error"))
            assertEquals(failed, retry.getJSONObject("input").getString("reuse_media"))
            assertEquals(1, store.removeUnusedVideos())
            assertTrue(inUse.isFile)
            assertFalse(unused.exists())
            assertEquals("completed", store.get(completed).getString("status"))
        } finally {
            for (id in listOf(first, second, failed, completed)) {
                store.cancelQueued(id)
                store.delete(id)
            }
        }
    }

    @Test fun exportCreatesAReadableDownloadsCopy() {
        if (Build.VERSION.SDK_INT < 29) return
        val name = "brb-export-test-${java.util.UUID.randomUUID()}.mp4"
        val source = File(context.cacheDir, name).also(::fixture)
        val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val resolver = context.contentResolver
        val where = "${MediaStore.MediaColumns.DISPLAY_NAME} = ?"
        try {
            assertEquals(name, media.exportToDownloads(source, name))
            val uri = resolver.query(collection, arrayOf(MediaStore.MediaColumns._ID), where, arrayOf(name), null)
                ?.use {
                    assertTrue(it.moveToFirst())
                    android.content.ContentUris.withAppendedId(collection, it.getLong(0))
                } ?: error("Missing export")
            assertArrayEquals(source.readBytes(), resolver.openInputStream(uri)!!.use { it.readBytes() })
        } finally {
            resolver.delete(collection, where, arrayOf(name))
            source.delete()
        }
    }
}
