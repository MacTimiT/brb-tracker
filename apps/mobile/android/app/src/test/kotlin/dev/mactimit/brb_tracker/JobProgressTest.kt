package dev.mactimit.brb_tracker

import org.junit.Assert.*
import org.junit.Test

class JobProgressTest {
    @Test fun downloadAndAnalysisHaveSeparatePercentagesAndRejectLateDownloadCallbacks() {
        val progress = JobProgress()
        assertTrue(progress.update(JobPhase.PREPARING, null))
        assertNull(progress.fraction)
        assertTrue(progress.update(JobPhase.DOWNLOAD, 0.75))
        assertEquals(0.75, progress.fraction!!, 0.001)
        assertTrue(progress.update(JobPhase.ANALYSIS, 0.0))
        assertEquals(0.0, progress.fraction!!, 0.001)
        assertFalse(progress.update(JobPhase.DOWNLOAD, 1.0))
        assertEquals(JobPhase.ANALYSIS, progress.phase)
        assertTrue(progress.update(JobPhase.ANALYSIS, 0.4))
        assertFalse(progress.update(JobPhase.ANALYSIS, 0.2))
        assertEquals(0.4, progress.fraction!!, 0.001)
    }
    @Test fun localVideoSkipsDownloadAndUnknownProgressStaysIndeterminate() {
        val progress = JobProgress()
        assertTrue(progress.update(JobPhase.ANALYSIS, null))
        assertNull(progress.fraction)
        assertTrue(progress.update(JobPhase.ANALYSIS, 0.0))
        assertEquals(0.0, progress.fraction!!, 0.001)
    }
}
