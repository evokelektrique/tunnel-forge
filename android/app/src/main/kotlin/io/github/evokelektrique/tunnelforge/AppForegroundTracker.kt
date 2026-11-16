package io.github.evokelektrique.tunnelforge

/** Tracks whether MainActivity is currently resumed and visible to the user. */
internal object AppForegroundTracker {
    @Volatile
    private var foreground = false

    fun setForeground(isForeground: Boolean) {
        foreground = isForeground
    }

    fun isForeground(): Boolean = foreground
}
