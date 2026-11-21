package dev.mactimit.brb_tracker

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Process
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.util.UUID

class JobStore(context: Context) {
    private val appContext = context.applicationContext
    private val media = VodFiles(context)
    private val queueOrder = AtomicFile(File(context.noBackupFilesDir, "brb-queue-order.json"))
    private val directory = File(context.noBackupFilesDir, "brb-jobs").apply { mkdirs() }
    companion object {
        private val lock = Any()
        private val pending = setOf("queued", "running")
        private val internalFields = setOf("input", "report", "diagnostic", "worker_pid", "worker_started_ms")
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

    fun removeUnusedVideos(): Int = synchronized(lock) {
        val snapshot = jobs()
        val inUse = snapshot.filter { it.optString("status") in pending }.map(::mediaId).toSet()
        val removable = snapshot.map(::mediaId).distinct().filter { it !in inUse && media.video(it).isFile }
        removable.forEach(media::delete)
        removable.size
    }

    private fun queueTime(job: JSONObject) = job.optString("queued_at", job.optString("created_at"))
    private fun queueKey(job: JSONObject) = job.getString("id") + "@" + queueTime(job)

    private fun orderedQueue(snapshot: List<JSONObject>): List<JSONObject> {
        val order = runCatching {
            val values = JSONArray(queueOrder.openRead().bufferedReader().use { it.readText() })
            (0 until values.length()).associate { values.getString(it) to it }
        }.getOrDefault(emptyMap())
        return snapshot.filter { it.optString("status") == "queued" }
            .sortedWith(compareBy<JSONObject> { order[queueKey(it)] ?: Int.MAX_VALUE }
                .thenBy { runCatching { Instant.parse(queueTime(it)) }.getOrDefault(Instant.EPOCH) })
    }

    fun queuedId(): String? = synchronized(lock) {
        orderedQueue(jobs()).firstOrNull()?.getString("id")
    }

    fun moveUp(id: String) = synchronized(lock) {
        val order = orderedQueue(jobs()).toMutableList()
        val index = order.indexOfFirst { it.getString("id") == id }
        check(index >= 0) { "This scan is no longer waiting in the queue." }
        if (index > 0) {
            java.util.Collections.swap(order, index - 1, index)
            write(queueOrder, JSONArray(order.map(::queueKey)).toString())
        }
    }

    private fun retryKey(job: JSONObject): String? {
        val input = job.optJSONObject("input") ?: return null
        val source = sourceId(input) ?: input.optString("video_uri").takeIf { it.isNotBlank() } ?: return null
        return if (input.has("probe_seconds")) "$source@${input.optDouble("probe_seconds")}" else source
    }

    fun retryFailed(id: String? = null): Int = synchronized(lock) {
        val snapshot = jobs()
        val keyInQueue = snapshot.filter { it.optString("status") in pending }.mapNotNull(::retryKey).toMutableSet()
        val handled = mutableSetOf<String>()
        val candidates = if (id == null) snapshot else listOf(get(id))
        val attempts = candidates.filter { job ->
            val key = retryKey(job) ?: return@filter false
            val status = job.optString("status")
            if (id == null && status != "cancelled" && !handled.add(key)) return@filter false
            status == "failed" && key !in keyInQueue && (id != null || !job.getJSONObject("input").has("probe_seconds"))
        }.asReversed()
        for (job in attempts) {
            val key = mediaId(job)
            val input = job.getJSONObject("input")
            if (media.video(key).isFile) input.put("reuse_media", key) else input.remove("reuse_media")
            job.put("status", "queued").put("stage", "Queued").put("progress", 0.0)
                .put("queued_at", Instant.now().toString())
            for (field in listOf("error", "phase", "phase_progress", "worker_pid", "worker_started_ms")) job.remove(field)
            save(job)
        }
        attempts.size
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
        write(AtomicFile(file(job.getString("id"))), job.toString())
    }
    private fun write(atomic: AtomicFile, text: String) {
        val stream = atomic.startWrite()
        try { stream.write(text.toByteArray(Charsets.UTF_8)); atomic.finishWrite(stream) }
        catch (e: Exception) { atomic.failWrite(stream); throw e }
    }
    fun update(id: String, change: (JSONObject) -> Unit): JSONObject = synchronized(lock) { get(id).also { change(it); save(it) } }
    fun list(): JSONArray = synchronized(lock) {
        val snapshot = jobs()
        val positions = orderedQueue(snapshot).mapIndexed { index, job -> job.getString("id") to index + 1 }.toMap()
        val inUse = snapshot.filter { it.optString("status") in pending }.map(::mediaId).toSet()
        val sizes = mutableMapOf<String, Pair<Long, Long>>()
        JSONArray(snapshot.map { job ->
            JSONObject().apply {
                for (key in job.keys()) {
                    if (key !in internalFields) put(key, job.get(key))
                }
                val key = mediaId(job)
                val video = media.video(key)
                val (videoBytes, retainedBytes) = sizes.getOrPut(key) {
                    val bytes = video.length()
                    bytes to (bytes + media.captions(key).length() + media.audio(key).length())
                }
                put("has_video", video.isFile)
                if (videoBytes > 0L) {
                    put("media_key", key).put("video_bytes", videoBytes).put("retained_bytes", retainedBytes)
                        .put("media_in_use", key in inUse)
                }
                positions[job.getString("id")]?.let { put("queue_position", it) }
                val input = job.optJSONObject("input")
                put("can_rescan", retryKey(job) != null)
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
    fun review(id: String, index: Int, reason: String, additional: List<String>? = null): JSONObject = synchronized(lock) {
        require(reason in Detection.reasons) { "Unknown reason category" }
        val job = get(id)
        val report = job.getJSONObject("report")
        require(index >= 0 && index < report.getJSONArray("breaks").length())
        val item = report.getJSONArray("breaks").getJSONObject(index)
        val existing = item.optJSONArray("additional_reasons")
        val extra = additional ?: if (reason == "Unknown" || existing == null) emptyList()
            else (0 until existing.length()).map(existing::getString).filterNot { it == reason }
        require(extra.distinct().size == extra.size && extra.all {
            it in Detection.reasons && it != reason && it != "Unknown" && reason != "Unknown"
        }) { "Choose distinct additional reasons." }
        item.put("reason", reason).put("confidence", "manual").put("reviewed", true)
        if (extra.isEmpty()) item.remove("additional_reasons") else item.put("additional_reasons", JSONArray(extra))
        save(job)
        report
    }
    fun recoverInterrupted() = synchronized(lock) {
        for (job in jobs()) {
            if (job.optString("status") == "running") update(job.getString("id")) {
                val lastStage = it.optString("stage", "Preparing")
                val reason = stopReason(it)
                it.put("status", "failed").put("stage", "Failed").put("phase", "failed").put("phase_progress", JSONObject.NULL)
                    .put("error", "$reason Last step: $lastStage. Use Retry scan to try again.")
            }
        }
    }
    private fun stopReason(job: JSONObject): String {
        val pid = job.optInt("worker_pid")
        val started = job.optLong("worker_started_ms")
        val reason = if (Build.VERSION.SDK_INT >= 30 && pid > 0 && pid != Process.myPid() && started > 0) {
            runCatching {
                appContext.getSystemService(ActivityManager::class.java)
                    .getHistoricalProcessExitReasons(appContext.packageName, pid, 1)
                    .firstOrNull { it.timestamp >= started }?.reason
            }.getOrNull()
        } else null
        return when (reason) {
            ApplicationExitInfo.REASON_LOW_MEMORY -> "Android stopped the scan because the phone ran low on memory."
            ApplicationExitInfo.REASON_ANR -> "Android stopped the scan after the app became unresponsive."
            ApplicationExitInfo.REASON_CRASH, ApplicationExitInfo.REASON_CRASH_NATIVE -> "The app crashed during the scan."
            else -> "Android interrupted the scan."
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
