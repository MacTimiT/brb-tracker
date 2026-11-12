package dev.mactimit.brb_tracker

import org.junit.Assert.*
import org.junit.Test

class ScanPlanTest {
    @Test fun longVodRefinesTransitionsAndChecksFewerFrames() {
        val duration = 12 * 3600.0
        fun present(time: Double) = time >= 3602.0 && time < 3723.0 || time >= 42001.0
        val samples = sortedMapOf<Double, Boolean?>()
        var time = 0.0
        while (time < duration) { samples[time] = present(time); time += 5 }
        samples[duration - 0.001] = present(duration - 0.001)
        for (fine in ScanPlan.refine(samples)) samples[fine] = present(fine)
        val detector = BreakDetector()
        samples.forEach { (t, p) -> detector.sample(t, p!!) }
        val breaks = detector.finish(duration)
        assertEquals(2, breaks.size)
        assertEquals(3602.0, breaks[0].start, 0.001)
        assertEquals(3723.0, breaks[0].end, 0.001)
        assertEquals(42001.0, breaks[1].start, 0.001)
        assertTrue(breaks[1].truncated)
        assertTrue("Expected far fewer than 21600 checks, got ${samples.size}", samples.size < 8700)
    }
    @Test fun unknownFramesAreRefinedAndCoarseSingletonCanBecomeConfirmedBreak() {
        assertEquals(listOf(1.0, 2.0, 3.0, 4.0), ScanPlan.refine(mapOf(0.0 to false, 5.0 to null)))
        val samples = sortedMapOf<Double, Boolean?>(0.0 to false, 5.0 to true, 10.0 to false)
        for (time in ScanPlan.refine(samples)) samples[time] = time >= 4 && time < 7
        val detector = BreakDetector()
        samples.forEach { (t, p) -> detector.sample(t, p!!) }
        val result = detector.finish(10.0)
        assertEquals(1, result.size)
        assertEquals(4.0, result[0].start, 0.0)
        assertEquals(7.0, result[0].end, 0.0)
    }
    @Test fun exactBannerCacheAvoidsOcrAndNeverReusesDifferentPixelsOrGeometry() {
        val cache = BannerCache()
        var reads = 0
        fun recognize(pixels: IntArray, width: Int, result: Boolean) = cache.recognize(pixels, width) { reads++; result }
        assertTrue(recognize(intArrayOf(0, 1, 1, 0), 2, true))
        assertTrue(recognize(intArrayOf(0, 1, 1, 0), 2, false))
        assertFalse(recognize(intArrayOf(0, 1, 0, 0), 2, false))
        assertFalse(recognize(intArrayOf(0, 1, 0, 0), 4, false))
        assertEquals(3, reads)
        assertEquals(1, cache.hits)
    }
}
