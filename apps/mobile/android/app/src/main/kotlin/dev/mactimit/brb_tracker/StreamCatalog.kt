package dev.mactimit.brb_tracker

import android.content.Context
import android.util.AtomicFile
import java.io.File
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import org.json.JSONArray
import org.json.JSONObject

object StreamCatalog {
    private const val channel = "https://www.youtube.com/@Gamin4Hope/streams"
    internal const val pageSize = 20
    private val videoId = Regex("[A-Za-z0-9_-]{11}")

    private fun cache(context: Context) = AtomicFile(File(context.cacheDir, "brb-streams.json"))

    @Synchronized fun cached(context: Context): String? = runCatching {
        cache(context).openRead().bufferedReader().use { it.readText() }
    }.getOrNull()

    @Synchronized private fun save(context: Context, page: JSONObject) {
        val file = cache(context)
        val stream = file.startWrite()
        try {
            stream.write(page.toString().toByteArray(Charsets.UTF_8))
            file.finishWrite(stream)
        } catch (e: Exception) {
            file.failWrite(stream)
            throw e
        }
    }

    fun load(context: Context, start: Int): JSONObject {
        require(start in 1..100_000)
        YoutubeDL.init(context.applicationContext)
        val request = YoutubeDLRequest(channel).apply {
            addOption("--ignore-config")
            addOption("--flat-playlist")
            addOption("--skip-download")
            addOption("--dump-single-json")
            // The inclusive range asks for one extra slot to establish whether more exist.
            addOption("--playlist-items", "$start:${start + pageSize}")
            addOption("--socket-timeout", 15)
            addOption("--retries", 1)
            addOption("--extractor-retries", 1)
        }
        val result = page(JSONObject(YoutubeDL.execute(request, null, null).out), start)
        if (start == 1) runCatching { save(context, result) }
        return result
    }

    internal fun page(playlist: JSONObject, start: Int): JSONObject {
        val entries = playlist.getJSONArray("entries")
        val streams = JSONArray()
        val seen = mutableSetOf<String>()
        for (index in 0 until minOf(pageSize, entries.length())) {
            val entry = entries.optJSONObject(index) ?: continue
            val id = entry.optString("id")
            val title = entry.optString("title").trim()
            if (!videoId.matches(id) || title.isEmpty() || title == "[Private video]" || title == "[Deleted video]") continue
            if (entry.optString("live_status") in setOf("is_live", "is_upcoming", "post_live")) continue
            if (seen.add(id)) streams.put(JSONObject().put("id", id).put("title", title))
        }
        val next = if (entries.length() > pageSize) start + pageSize else JSONObject.NULL
        return JSONObject().put("streams", streams).put("next", next)
    }
}
