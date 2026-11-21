package dev.mactimit.brb_tracker

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class VodMetadataTest {
    @Test fun metadataSignInChallengeIsRecognizedWithoutMaskingOtherFailures() {
        for (challenge in listOf("Sign in to confirm youre not a bot.", "Sign in to confirm you’re not a bot.")) {
            val message = VodMetadata.signInChallengeMessage("WARNING: No title found\nERROR: [youtube] fixture0001: $challenge")
            assertTrue(message.orEmpty().contains("YouTube asked for sign-in verification"))
        }
        assertNull(VodMetadata.signInChallengeMessage("ERROR: [youtube] fixture0001: Video unavailable"))
        assertNull(VodMetadata.signInChallengeMessage(null))
    }
    @Test fun oldLivestreamDateWinsOverUploadAndScanDate() {
        val source = JSONObject().put("release_timestamp", Instant.parse("2026-10-22T23:30:00Z").epochSecond)
            .put("upload_date", "20261112").put("timestamp", Instant.parse("2026-11-12T12:00:00Z").epochSecond)
        val dates = VodMetadata.date(source)
        assertEquals("2026-10-22", dates.getString("vod_date"))
        assertEquals("release_timestamp", dates.getString("vod_date_source"))
        assertEquals("2026-10-22T23:30:00Z", dates.getString("stream_started_at"))
        source.put("live_start_timestamp", Instant.parse("2026-10-21T23:30:00Z").epochSecond)
        assertEquals("2026-10-21", VodMetadata.date(source).getString("vod_date"))
    }
    @Test fun releaseDatePrecedesUploadAndUnknownNeverBecomesToday() {
        val release = VodMetadata.date(JSONObject().put("release_date", "20261022").put("upload_date", "20261112"))
        assertEquals("2026-10-22", release.getString("vod_date"))
        val upload = VodMetadata.date(JSONObject().put("upload_date", "20261022"))
        assertEquals("upload_date", upload.getString("vod_date_source"))
        assertTrue(upload.isNull("stream_started_at"))
        for (metadata in listOf(JSONObject(), JSONObject().put("upload_date", "nonsense"))) {
            assertTrue(VodMetadata.date(metadata).isNull("vod_date"))
            assertEquals("unknown", VodMetadata.date(metadata).getString("vod_date_source"))
        }
    }
    @Test fun videoOnlyFormatIsPreferredAtSelectedResolution() {
        assertTrue(VodMetadata.format(360).startsWith("bestvideo[height<=360]"))
        assertTrue(VodMetadata.format(480).contains("/best[height<=480]"))
        assertThrows(IllegalArgumentException::class.java) { VodMetadata.format(720) }
        assertEquals(2, VodMetadata.format(360, "134-0").split("[format_id!=134-0]").size - 1)
        assertFalse(VodMetadata.format(360, "bad]filter").contains("bad]filter"))
    }

    @Test fun onlyMissingMediaCanTriggerTheDirectMp4Retry() {
        val empty = "ERROR: The downloaded file is empty"
        assertTrue(VodMetadata.missingMedia(empty))
        assertTrue(VodMetadata.missingMedia("ERROR: fragment 5 not found, unable to continue"))
        assertFalse(VodMetadata.missingMedia("ERROR: [youtube] fixture0001: Sign in to confirm youre not a bot.\n$empty"))
        assertFalse(VodMetadata.missingMedia("HTTP Error 403: Forbidden\n$empty"))
        assertFalse(VodMetadata.missingMedia("ERROR: No space left on device"))
    }

    @Test fun preflightUsesTheSelectedFormatSizeWhenAvailable() {
        val metadata = VodMetadata.parse("  {\"title\":\"Test VOD\",\"filesize\":600,\"filesize_approx\":900}\n")
        assertEquals(600L, VodMetadata.estimatedDownloadBytes(metadata))
        assertEquals(900L, VodMetadata.estimatedDownloadBytes(JSONObject().put("filesize_approx", 900)))
        assertEquals(null, VodMetadata.estimatedDownloadBytes(JSONObject()))
        assertThrows(IllegalStateException::class.java) { VodMetadata.parse("\n") }
    }
}
