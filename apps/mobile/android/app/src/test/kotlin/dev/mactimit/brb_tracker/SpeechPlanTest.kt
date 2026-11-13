package dev.mactimit.brb_tracker

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class SpeechPlanTest {
    @Test fun mergesOverlappingLookbacks() {
        assertEquals(listOf(AudioWindow(40.0, 140.0), AudioWindow(240.0, 300.0)),
            SpeechPlan.windows(listOf(100.0, 140.0, 300.0)))
        assertEquals(emptyList<AudioWindow>(), SpeechPlan.windows(listOf(0.0)))
    }

    @Test fun downmixesAndResamplesStereoPcm() {
        val input = ByteBuffer.allocate(6 * 2 * 2).order(ByteOrder.LITTLE_ENDIAN)
        repeat(6) { input.putShort(1000); input.putShort(3000) }
        input.flip()
        val result = Pcm16Resampler(48_000, 2).convert(input)
        assertEquals(4, result.size)
        val output = ByteBuffer.wrap(result).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(2000, output.short.toInt())
        assertEquals(2000, output.short.toInt())
        assertTrue(!output.hasRemaining())
    }

    @Test fun voskWordsBecomeTimedReasonEvidence() {
        val json = """{"result":[{"start":1.0,"end":1.2,"word":"i"},{"start":1.3,"end":1.6,"word":"need"},{"start":1.7,"end":1.9,"word":"to"},{"start":2.0,"end":2.4,"word":"pee"}]}"""
        val cues = SpeechPlan.cues(SpeechPlan.parseWords(json, 95.0), listOf(100.0))
        assertEquals(1, cues.size)
        assertEquals(96.0, cues.single().start, 0.001)
        assertEquals(97.4, cues.single().end, 0.001)
        assertEquals("i need to pee", cues.single().text)
        assertEquals("Pee", Detection.reason(cues, 100.0).first)
    }

    @Test fun speechAfterBreakCannotChangeItsReason() {
        val words = listOf(
            SpeechWord(98.0, 98.2, "i"), SpeechWord(98.3, 98.6, "need"), SpeechWord(98.7, 98.9, "to"), SpeechWord(99.0, 99.3, "pee"),
            SpeechWord(100.2, 100.4, "i"), SpeechWord(100.5, 100.8, "need"), SpeechWord(100.9, 101.1, "a"), SpeechWord(101.2, 101.6, "snack")
        )
        assertEquals("Pee", Detection.reason(SpeechPlan.cues(words, listOf(100.0)), 100.0).first)
    }
}
