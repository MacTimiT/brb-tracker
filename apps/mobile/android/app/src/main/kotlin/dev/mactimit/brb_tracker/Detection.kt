package dev.mactimit.brb_tracker

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

data class Cue(val start: Double, val end: Double, val text: String)
data class DetectedBreak(val start: Double, val end: Double, val truncated: Boolean = false)

/** Streaming debounce: timestamps are sampled estimates, never exact absence times. */
class BreakDetector(private val minHits: Int = 2, private val endMisses: Int = 2) {
    private var start: Double? = null
    private var firstMiss: Double? = null
    private var hits = 0
    private var misses = 0
    private var active = false
    private var previous = -1.0
    private val result = mutableListOf<DetectedBreak>()
    init { require(minHits > 0 && endMisses > 0) }
    fun sample(time: Double, present: Boolean) {
        require(time.isFinite() && time >= 0 && time > previous)
        previous = time
        if (present) {
            if (start == null) start = time
            hits++
            misses = 0
            firstMiss = null
            active = active || hits >= minHits
        } else if (!active) {
            start = null
            hits = 0
        } else {
            if (firstMiss == null) firstMiss = time
            misses++
            if (misses >= endMisses) {
                result.add(DetectedBreak(start!!, firstMiss!!))
                start = null
                firstMiss = null
                hits = 0
                misses = 0
                active = false
            }
        }
    }
    fun finish(duration: Double): List<DetectedBreak> {
        require(duration.isFinite() && duration >= previous)
        return result.toList() + if (active) listOf(DetectedBreak(start!!, duration, true)) else emptyList()
    }
}

object Detection {
    val reasons = setOf("Pee", "Snack", "Drink", "Stretch", "Technical", "Other", "Unknown")
    private val phrase = Regex("\\bbe right back\\b")
    private val intent = Regex("\\b(i|i'm|im|i’ll|i'll|gonna|going to|gotta|need to|have to|let me|grab|brb|be right back)\\b", RegexOption.IGNORE_CASE)
    private val negation = Regex("\\b(not|don't|dont|won't|wont|isn't|isnt|never|no)\\b", RegexOption.IGNORE_CASE)
    private val patterns = mapOf(
        "Pee" to "\\b(pee|piss|bathroom|restroom|toilet|bio break)\\b",
        "Snack" to "\\b(snack|food|lunch|dinner|breakfast|sandwich|eat|eating)\\b",
        "Drink" to "\\b(water|drink|coffee|tea|hydrate|refill)\\b",
        "Stretch" to "\\b(stretch|stretching|walk|walking)\\b",
        "Technical" to "\\b(restart|reboot|technical|fix (?:the |my )?(?:audio|mic|camera))\\b"
    ).mapValues { Regex(it.value, RegexOption.IGNORE_CASE) }
    fun isBrb(text: String) = phrase.containsMatchIn(text.lowercase().replace(Regex("[^a-z0-9]+"), " ").trim())

    fun reason(cues: List<Cue>, start: Double): Pair<String, String> {
        val recent = cues.filter { it.start >= start - 60 && it.end <= start }.sortedBy { it.start }.takeLast(5)
        val evidence = recent.joinToString(" ") { it.text }
        for (cue in recent.asReversed()) for (sentence in cue.text.split(Regex("[.!?]+")).asReversed()) {
            if (!intent.containsMatchIn(sentence) || negation.containsMatchIn(sentence)) continue
            val matches = patterns.filterValues { it.containsMatchIn(sentence) }.keys
            if (matches.size == 1) return matches.first() to evidence
            if (matches.size > 1) return "Unknown" to evidence
        }
        return "Unknown" to evidence
    }

    fun videoId(url: String): String {
        val uri = URI(url.trim())
        require(uri.scheme == "https" && uri.userInfo == null && uri.port in listOf(-1, 443)) { "Use an HTTPS YouTube VOD URL" }
        val host = uri.host?.lowercase()
        val parts = uri.path.trim('/').split('/')
        val id = when {
            host == "youtu.be" -> uri.path.trim('/')
            host in setOf("youtube.com", "www.youtube.com", "m.youtube.com") && parts.size == 2 && parts[0] in setOf("live", "shorts") -> parts[1]
            host in setOf("youtube.com", "www.youtube.com", "m.youtube.com") && uri.path == "/watch" -> uri.rawQuery.orEmpty().split('&').firstOrNull { it.startsWith("v=") }?.substringAfter('=') ?: ""
            else -> ""
        }
        require(Regex("[A-Za-z0-9_-]{11}").matches(id)) { "Expected one YouTube video, not a channel or playlist" }
        return id
    }

    fun parseTranscript(text: String): List<Cue> {
        val trimmed = text.trimStart('\uFEFF', ' ', '\n', '\r', '\t')
        if (trimmed.startsWith("[")) {
            val array = JSONArray(trimmed)
            return (0 until array.length()).map { i -> array.getJSONObject(i).let { Cue(it.getDouble("start"), it.getDouble("end"), it.getString("text")) } }.also(::validateCues)
        }
        if (trimmed.startsWith("{")) {
            val events = JSONObject(trimmed).optJSONArray("events") ?: return emptyList()
            return (0 until events.length()).mapNotNull { index ->
                val event = events.getJSONObject(index)
                val segments = event.optJSONArray("segs") ?: return@mapNotNull null
                val words = (0 until segments.length()).joinToString("") { segments.getJSONObject(it).optString("utf8") }.trim()
                if (words.isEmpty()) null else {
                    val start = event.getDouble("tStartMs") / 1000
                    Cue(start, start + event.optDouble("dDurationMs", 0.0) / 1000, words)
                }
            }.also(::validateCues)
        }
        fun seconds(stamp: String) = stamp.split(':').reversed().mapIndexed { index, value -> value.toDouble() * Math.pow(60.0, index.toDouble()) }.sum()
        val result = mutableListOf<Cue>()
        trimmed.replace("\r\n", "\n").split(Regex("\n\\s*\n")).forEach { block ->
            val lines = block.lines()
            val index = lines.indexOfFirst { it.contains(" --> ") }
            if (index < 0) return@forEach
            val stamps = lines[index].split(" --> ")
            val words = lines.drop(index + 1).joinToString(" ").replace(Regex("<[^>]+>"), "")
                .replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&#39;", "'").replace("&quot;", "\"").trim()
            if (words.isNotEmpty()) {
                val cue = Cue(seconds(stamps[0].trim()), seconds(stamps[1].trim().split(' ')[0]), words)
                if (result.lastOrNull()?.text == words) result[result.lastIndex] = result.last().copy(end = maxOf(result.last().end, cue.end)) else result.add(cue)
            }
        }
        return result.also(::validateCues)
    }
    private fun validateCues(cues: List<Cue>) { require(cues.all { it.start.isFinite() && it.end.isFinite() && it.start >= 0 && it.end >= it.start }) { "Invalid transcript timing" } }
}
