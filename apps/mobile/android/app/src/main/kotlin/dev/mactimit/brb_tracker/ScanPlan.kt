package dev.mactimit.brb_tracker

/** Coarse samples discover candidates; only changed/unknown spans need a fine pass. */
object ScanPlan {
    fun refine(samples: Map<Double, Boolean?>, step: Double = 1.0): List<Double> {
        require(step.isFinite() && step > 0)
        return samples.toSortedMap().entries.zipWithNext().flatMap { (left, right) ->
            if (left.value != null && left.value == right.value) emptyList()
            else buildList {
                var time = left.key + step
                while (time < right.key) { add(time); time += step }
            }
        }
    }
}

/** Exact binary mask reuse cannot turn a different banner into a positive match. */
class BannerCache {
    private var previous: IntArray? = null
    private var previousWidth = 0
    private var result = false
    var hits = 0
        private set
    fun recognize(pixels: IntArray, width: Int, read: () -> Boolean): Boolean {
        if (width == previousWidth && previous?.contentEquals(pixels) == true) {
            hits++
            return result
        }
        result = read()
        previous = pixels.copyOf()
        previousWidth = width
        return result
    }
}
