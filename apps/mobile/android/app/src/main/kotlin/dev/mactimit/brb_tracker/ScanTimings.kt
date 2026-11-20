package dev.mactimit.brb_tracker

import org.json.JSONObject

/** Elapsed wall time on this device, using a monotonic clock. */
class ScanTimings {
    private val started = System.nanoTime()
    private val phases = linkedMapOf<String, Long>()

    fun <T> measure(phase: String, action: () -> T): T {
        val before = System.nanoTime()
        try {
            return action()
        } finally {
            phases[phase] = (phases[phase] ?: 0) + System.nanoTime() - before
        }
    }

    fun report(): JSONObject = JSONObject().apply {
        for ((phase, elapsed) in phases) put(phase, elapsed / 1_000_000)
        put("total", (System.nanoTime() - started) / 1_000_000)
    }
}
