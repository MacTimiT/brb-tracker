package dev.mactimit.brb_tracker

import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

object VodMetadata {
    fun date(metadata: JSONObject): JSONObject {
        for (field in listOf("live_start_timestamp", "release_timestamp")) {
            val seconds = metadata.optDouble(field, Double.NaN)
            if (seconds.isFinite() && seconds > 0) {
                val instant = runCatching { Instant.ofEpochSecond(seconds.toLong()) }.getOrNull() ?: continue
                return JSONObject().put("vod_date", instant.atOffset(ZoneOffset.UTC).toLocalDate().toString())
                    .put("vod_date_source", field).put("stream_started_at", if (field == "live_start_timestamp" || field == "release_timestamp") instant.toString() else JSONObject.NULL)
            }
        }
        for (field in listOf("release_date")) {
            val date = runCatching { LocalDate.parse(metadata.optString(field), DateTimeFormatter.BASIC_ISO_DATE) }.getOrNull()
            if (date != null) return JSONObject().put("vod_date", date.toString()).put("vod_date_source", field).put("stream_started_at", JSONObject.NULL)
        }
        val uploaded = metadata.optDouble("timestamp", Double.NaN)
        if (uploaded.isFinite() && uploaded > 0) {
            val instant = runCatching { Instant.ofEpochSecond(uploaded.toLong()) }.getOrNull()
            if (instant != null) return JSONObject().put("vod_date", instant.atOffset(ZoneOffset.UTC).toLocalDate().toString())
                .put("vod_date_source", "timestamp").put("stream_started_at", JSONObject.NULL)
        }
        val uploadDate = runCatching { LocalDate.parse(metadata.optString("upload_date"), DateTimeFormatter.BASIC_ISO_DATE) }.getOrNull()
        if (uploadDate != null) return JSONObject().put("vod_date", uploadDate.toString()).put("vod_date_source", "upload_date").put("stream_started_at", JSONObject.NULL)
        return JSONObject().put("vod_date", JSONObject.NULL).put("vod_date_source", "unknown").put("stream_started_at", JSONObject.NULL)
    }
    fun format(height: Int): String {
        require(height in listOf(360, 480)) { "Choose 360p or 480p" }
        // Prefer AVC video-only; combined MP4 is a compatibility fallback.
        return "bestvideo[height<=$height][ext=mp4][vcodec^=avc1]/best[height<=$height][ext=mp4][vcodec^=avc1]"
    }
}
