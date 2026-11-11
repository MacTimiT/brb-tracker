package dev.mactimit.brb_tracker

import org.junit.Assert.*
import org.junit.Test

class DetectionTest {
    @Test fun phraseNormalizationAndBoundaries() {
        assertTrue(Detection.isBrb("BE\nRIGHT BACK!"))
        assertFalse(Detection.isBrb("be right backward"))
        assertFalse(Detection.isBrb("BRB"))
    }
    @Test fun dropoutAndFalsePositiveTiming() {
        val detector = BreakDetector()
        listOf(false, true, false, true, true, false, true, false, false).forEachIndexed { i, hit -> detector.sample(i * 2.0, hit) }
        assertEquals(listOf(DetectedBreak(6.0, 14.0)), detector.finish(18.0))
    }
    @Test fun eofAndNoDetection() {
        val detector = BreakDetector()
        detector.sample(0.0, true); detector.sample(2.0, true)
        assertEquals(listOf(DetectedBreak(0.0, 4.0, true)), detector.finish(4.0))
        assertTrue(BreakDetector().finish(0.0).isEmpty())
    }
    @Test fun precedingCuesOnly() {
        val cues = listOf(Cue(80.0, 85.0, "I gotta pee."), Cue(99.0, 101.0, "I'm getting a snack."), Cue(110.0, 115.0, "I need water."))
        assertEquals("Pee", Detection.reason(cues, 100.0).first)
        assertFalse(Detection.reason(cues, 100.0).second.contains("snack"))
        assertEquals("Unknown", Detection.reason(cues, 200.0).first)
    }
    @Test fun ambiguousAndNegatedReasons() {
        for (text in listOf("I don't need to pee", "I need a snack and a drink", "The game has a bathroom")) assertEquals("Unknown", Detection.reason(listOf(Cue(2.0, 4.0, text)), 6.0).first)
        assertEquals("Technical", Detection.reason(listOf(Cue(2.0, 4.0, "Let me fix my mic")), 6.0).first)
        assertEquals("Drink", Detection.reason(listOf(Cue(2.0, 4.0, "I'm getting water")), 6.0).first)
    }
    @Test fun captionFormatsAndRollingDuplicates() {
        val vtt = "WEBVTT\n\n00:00:02.000 --> 00:00:04.000\nI need water\n\n00:00:04.000 --> 00:00:06.000\nI need water\n"
        assertEquals(listOf(Cue(2.0, 6.0, "I need water")), Detection.parseTranscript(vtt))
        val json3 = """{"events":[{"tStartMs":2000,"dDurationMs":2000,"segs":[{"utf8":"I need water"}]}]}"""
        assertEquals(listOf(Cue(2.0, 4.0, "I need water")), Detection.parseTranscript(json3))
        assertEquals(listOf(Cue(2.0, 4.0, "I need water")), Detection.parseTranscript("""[{"start":2,"end":4,"text":"I need water"}]"""))
    }
    @Test fun strictYouTubeInputs() {
        assertEquals("IW2rEIuKGSs", Detection.videoId("https://www.youtube.com/live/IW2rEIuKGSs"))
        assertEquals("IW2rEIuKGSs", Detection.videoId("https://youtu.be/IW2rEIuKGSs?t=30"))
        for (url in listOf("http://youtube.com/watch?v=IW2rEIuKGSs", "https://youtube.com.evil.com/watch?v=IW2rEIuKGSs", "https://localhost/", "https://youtube.com/playlist?list=x")) {
            try { Detection.videoId(url); fail("Accepted $url") } catch (_: IllegalArgumentException) { }
        }
    }
}
