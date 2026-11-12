package dev.mactimit.brb_tracker

enum class JobPhase(val label: String) {
    PREPARING("Preparing on-device downloader"),
    METADATA("Reading YouTube VOD details"),
    CAPTIONS("Downloading available English captions"),
    DOWNLOAD("Downloading video to this phone"),
    ANALYSIS("Scanning BRB screens locally")
}

/** Reject late callbacks from an earlier phase and backwards percentage updates. */
class JobProgress {
    var phase: JobPhase? = null
        private set
    var fraction: Double? = null
        private set

    @Synchronized fun update(next: JobPhase, value: Double?): Boolean {
        if (phase != null && next.ordinal < phase!!.ordinal) return false
        val normalized = value?.takeIf { it.isFinite() }?.coerceIn(0.0, 1.0)
        if (next == phase && fraction != null && (normalized == null || normalized < fraction!!)) return false
        if (next == phase && normalized?.times(100)?.toInt() == fraction?.times(100)?.toInt()) return false
        phase = next
        fraction = normalized
        return true
    }
}
