package com.leeguoo.jrkan.data

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Port of PlaybackHealthMonitor (App/Sources/Shared/PlaybackHealth.swift).
 * Samples media progress throughout playback. A paused player is not a stall.
 * Times are seconds as Double, from any monotonic clock the caller picks.
 */
class PlaybackHealthMonitor(now: Double) {
    sealed interface Event {
        data class Confirmed(val startupSeconds: Double) : Event
        data object Stalled : Event
    }

    private var lastSample = now
    private var lastProgress = now
    private var lastMediaTime: Double? = null
    private var activeElapsed = 0.0
    private var firstFrameElapsed: Double? = null
    private var stablePlayback = 0.0
    private var wasAdvancing = false
    var confirmed = false
        private set
    private var failed = false
    var startupTimeout = 20.0
    var stallTimeout = 12.0

    fun sample(
        now: Double,
        mediaTime: Double,
        playing: Boolean,
        paused: Boolean,
        ready: Boolean,
        itemFailed: Boolean,
    ): Event? {
        if (failed) return null
        val delta = max(0.0, now - lastSample)
        lastSample = now
        if (itemFailed) {
            failed = true
            return Event.Stalled
        }
        if (paused) {
            lastProgress = now
            lastMediaTime = if (mediaTime.isFinite()) mediaTime else null
            stablePlayback = 0.0
            wasAdvancing = false
            return null
        }
        activeElapsed += delta
        val previous = lastMediaTime
        val advancing = mediaTime.isFinite() && previous != null && abs(mediaTime - previous) > 0.05
        if (mediaTime.isFinite()) lastMediaTime = mediaTime
        if (playing && ready && advancing) {
            lastProgress = now
            stablePlayback = if (wasAdvancing) stablePlayback + min(delta, 1.0) else 0.0
            wasAdvancing = true
            if (firstFrameElapsed == null) firstFrameElapsed = activeElapsed
            if (!confirmed && stablePlayback >= 2) {
                confirmed = true
                return Event.Confirmed(firstFrameElapsed ?: activeElapsed)
            }
        } else {
            stablePlayback = 0.0
            wasAdvancing = false
        }
        val firstFrame = firstFrameElapsed
        if ((firstFrame == null && activeElapsed >= startupTimeout) ||
            (firstFrame != null && now - lastProgress >= stallTimeout)
        ) {
            failed = true
            return Event.Stalled
        }
        return null
    }
}
