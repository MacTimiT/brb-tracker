package dev.mactimit.brb_tracker

import android.content.Context
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.util.UUID

class JobStore(context: Context) {
    private val media = VodFiles(context)
    private val directory = File(context.noBackupFilesDir, "brb-jobs").apply { mkdirs() }
    companion object {
        private val lock = Any()
        private val pending = setOf("queued", "running")
    }
    private fun sourceId(input: JSONObject) = runCatching { Detection.videoId(input.getString("url")) }.getOrNull()
    private fun jobs() = directory.listFiles().orEmpty().filter { it.extension == "json" }
        .mapNotNull { runCatching { get(it.nameWithoutExtension) }.getOrNull() }
        .sortedByDescending { runCatching { Instant.parse(it.optString("created_at")) }.getOrDefault(Instant.EPOCH) }

    private fun mediaId(job: JSONObject) = job.optJSONObject("input")?.optString("reuse_media")
        ?.takeIf { it.isNotEmpty() } ?: job.getString("id")

    fun video(id: String) = synchronized(lock) { media.video(mediaId(get(id))) }

    fun rescanInput(id: String, settings: JSONObject): JSONObject = synchronized(lock) {
        val job = get(id)
        check(job.optString("status") !in pending) { "Wait until this scan finishes." }
        val input = job.getJSONObject("input")
        input.remove("probe_seconds")
        if (media.video(mediaId(job)).isFile) input.put("reuse_media", mediaId(job))
        else input.remove("reuse_media")
        for (key in settings.keys()) input.put(key, settings.get(key))
        input.put("title", job.optString("title", "VOD"))
        input
    }

    fun removeVideo(id: String) = synchronized(lock) {
        val key = mediaId(get(id))
        check(jobs().none { mediaId(it) == key && it.optString("status") in pending }) {
            "This video is in use by the queue."
        }
        media.delete(key)
    }

    fun queuedId(): String? = synchronized(lock) {
        jobs().lastOrNull { it.optString("status") == "queued" }?.getString("id")
    }

    fun cancelQueued(id: String): Boolean = synchronized(lock) {
        val job = get(id)
        if (job.optString("status") != "queued") return@synchronized false
        save(job.put("status", "cancelled").put("stage", "Cancelled").put("phase", "cancelled"))
        true
    }
    private fun file(id: String): File { require(Regex("[a-zA-Z0-9-]+").matches(id)); return File(directory, "$id.json") }
    fun create(input: JSONObject): JSONObject = synchronized(lock) {
        val videoId = sourceId(input)
        if (videoId != null && !input.has("probe_seconds")) {
            check(jobs().none {
                val existing = it.optJSONObject("input")
                it.optString("status") in pending && existing != null &&
                    !existing.has("probe_seconds") && sourceId(existing) == videoId
            }) { "This VOD is already in the queue." }
        }
        val id = UUID.randomUUID().toString()
        JSONObject().put("id", id).put("url", input.optString("url")).put("title", input.optString("title", "YouTube VOD"))
            .put("created_at", Instant.now().toString()).put("status", "queued").put("stage", "Queued")
            .put("progress", 0.0).put("input", input).also { save(it) }
    }
    fun get(id: String): JSONObject = synchronized(lock) { JSONObject(AtomicFile(file(id)).openRead().bufferedReader().use { it.readText() }) }
    fun save(job: JSONObject) = synchronized(lock) {
        val atomic = AtomicFile(file(job.getString("id")))
        val stream = atomic.startWrite()
        try { stream.write(job.toString().toByteArray(Charsets.UTF_8)); atomic.finishWrite(stream) }
        catch (e: Exception) { atomic.failWrite(stream); throw e }
    }
    fun update(id: String, change: (JSONObject) -> Unit): JSONObject = synchronized(lock) { get(id).also { change(it); save(it) } }
    fun list(): JSONArray = synchronized(lock) {
        JSONArray(jobs().map { job ->
            JSONObject().apply {
                for (key in job.keys()) {
                    if (key != "input" && key != "report" && key != "diagnostic") put(key, job.get(key))
                }
                put("has_video", media.video(mediaId(job)).isFile)
                val input = job.optJSONObject("input")
                put("can_rescan", input != null && (sourceId(input) != null || input.optString("video_uri").isNotBlank()))
                if (input != null && job.optString("status") in pending && !input.has("probe_seconds")) {
                    sourceId(input)?.let { put("queued_video_id", it) }
                }
                val report = job.optJSONObject("report")
                if (job.optString("status") == "completed" && report != null && !report.optBoolean("is_demo")) {
                    report.optString("video_id").takeIf { it.isNotBlank() && !report.isNull("video_id") }
                        ?.let { put("completed_video_id", it) }
                }
            }
        })
    }
    fun review(id: String, index: Int, reason: String): JSONObject = synchronized(lock) {
        require(reason in Detection.reasons) { "Unknown reason category" }
        val job = get(id)
        val report = job.getJSONObject("report")
        require(index >= 0 && index < report.getJSONArray("breaks").length())
        report.getJSONArray("breaks").getJSONObject(index).put("reason", reason).put("confidence", "manual").put("reviewed", true)
        save(job)
        report
    }
    fun recoverInterrupted() = synchronized(lock) {
        for (job in jobs()) {
            if (job.optString("status") == "running") update(job.getString("id")) {
                it.put("status", "failed").put("stage", "Failed").put("phase", "failed").put("phase_progress", JSONObject.NULL)
                    .put("error", "Android stopped the analysis. Submit the VOD again.")
            }
        }
    }
    fun delete(id: String) = synchronized(lock) {
        val job = get(id)
        check(job.optString("status") !in pending) { "Cancel the analysis first." }
        val key = mediaId(job)
        if (jobs().none { it.getString("id") != id && mediaId(it) == key }) media.delete(key)
        AtomicFile(file(id)).delete()
    }
}
