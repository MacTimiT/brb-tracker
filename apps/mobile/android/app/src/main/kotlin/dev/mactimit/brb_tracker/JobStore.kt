package dev.mactimit.brb_tracker

import android.content.Context
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.util.UUID

class JobStore(context: Context) {
    private val directory = File(context.noBackupFilesDir, "brb-jobs").apply { mkdirs() }
    companion object { private val lock = Any() }
    private fun file(id: String): File { require(Regex("[a-zA-Z0-9-]+").matches(id)); return File(directory, "$id.json") }
    fun create(input: JSONObject): JSONObject = synchronized(lock) {
        val id = UUID.randomUUID().toString()
        JSONObject().put("id", id).put("url", input.optString("url")).put("title", input.optString("title", "YouTube VOD"))
            .put("created_at", Instant.now().toString()).put("status", "queued").put("stage", "Preparing")
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
        val jobs = directory.listFiles().orEmpty().filter { it.extension == "json" }.mapNotNull { runCatching { get(it.nameWithoutExtension) }.getOrNull() }
            .sortedByDescending { it.optString("created_at") }
        JSONArray(jobs.map { JSONObject(it.toString()).apply { remove("input"); remove("report"); remove("diagnostic") } })
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
        val jobs = list()
        for (i in 0 until jobs.length()) {
            val job = jobs.getJSONObject(i)
            if (job.optString("status") in setOf("queued", "running")) update(job.getString("id")) {
                it.put("status", "failed").put("stage", "Failed").put("phase", "failed").put("phase_progress", JSONObject.NULL)
                    .put("error", "Android stopped the analysis. Submit the VOD again.")
            }
        }
    }
    fun delete(id: String) = synchronized(lock) { AtomicFile(file(id)).delete() }
}
