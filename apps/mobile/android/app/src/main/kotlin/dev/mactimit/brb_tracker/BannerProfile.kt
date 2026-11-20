package dev.mactimit.brb_tracker

/** Fractions are relative to the decoded VOD frame, not the phone display. */
object BannerProfile {
    val names = setOf("gamin4hope", "full_frame")
    fun bounds(width: Int, height: Int): IntArray {
        require(width > 0 && height > 0)
        val right = (width * 0.68).toInt().coerceIn(1, width)
        val top = (height * 0.68).toInt().coerceIn(0, height - 1)
        // The banner can start within the first 2% of the decoded frame.
        return intArrayOf(0, top, right, height)
    }
    fun isRed(r: Int, g: Int, b: Int) = r >= 120 && r * 10 >= g * 16 && r * 10 >= b * 14
}
