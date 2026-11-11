package dev.mactimit.brb_tracker

/** Fractions are relative to the decoded VOD frame, not the phone display. */
object BannerProfile {
    val names = setOf("gamin4hope", "full_frame")
    fun bounds(width: Int, height: Int): IntArray {
        require(width > 0 && height > 0)
        val left = (width * 0.05).toInt().coerceIn(0, width - 1)
        val right = (width * 0.68).toInt().coerceIn(left + 1, width)
        val top = (height * 0.68).toInt().coerceIn(0, height - 1)
        return intArrayOf(left, top, right, height)
    }
    fun isRed(r: Int, g: Int, b: Int) = r >= 120 && r * 10 >= g * 16 && r * 10 >= b * 14
}
