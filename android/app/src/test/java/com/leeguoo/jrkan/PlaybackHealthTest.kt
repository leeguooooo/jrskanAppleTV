package com.leeguoo.jrkan

import com.leeguoo.jrkan.data.PlaybackHealthMonitor
import com.leeguoo.jrkan.data.PlaybackHealthMonitor.Event
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of PlaybackHealthTests in App/Tests/ExperienceTests.swift. */
class PlaybackHealthTest {
    private fun PlaybackHealthMonitor.at(
        now: Double,
        media: Double,
        playing: Boolean,
        paused: Boolean = false,
        ready: Boolean = true,
        failed: Boolean = false,
    ) = sample(now, media, playing, paused, ready, failed)

    @Test
    fun lateFirstFrameCanFinishConfirmationAfterStartupDeadline() {
        val monitor = PlaybackHealthMonitor(0.0)
        for (halfSecond in 1..37) {
            assertNull(monitor.at(halfSecond / 2.0, 0.0, playing = false, ready = false))
        }
        for (halfSecond in 38..41) {
            assertNull(monitor.at(halfSecond / 2.0, (halfSecond - 37) / 2.0, playing = true))
        }
        assertEquals(Event.Confirmed(19.0), monitor.at(21.0, 2.5, playing = true))
    }

    @Test
    fun continuesMonitoringAfterFirstFrameAndDetectsFrozenPlayback() {
        val monitor = PlaybackHealthMonitor(0.0)
        var confirmations = 0
        for (second in 1..5) {
            if (monitor.at(second.toDouble(), second.toDouble(), playing = true) is Event.Confirmed) confirmations += 1
        }
        assertEquals(1, confirmations)
        assertTrue(monitor.confirmed)
        assertNull(monitor.at(16.0, 5.0, playing = true))
        assertEquals(Event.Stalled, monitor.at(17.0, 5.0, playing = true))
        assertNull(monitor.at(18.0, 5.0, playing = true))
    }

    @Test
    fun pauseIsNotAStallAndResumeRestartsTheWaitingWindow() {
        val monitor = PlaybackHealthMonitor(0.0)
        for (second in 1..4) monitor.at(second.toDouble(), second.toDouble(), playing = true)
        assertNull(monitor.at(100.0, 4.0, playing = false, paused = true))
        assertNull(monitor.at(1000.0, 4.0, playing = false, paused = true))
        assertNull(monitor.at(1001.0, 5.0, playing = true))
        assertNull(monitor.at(1012.0, 5.0, playing = false))
        assertEquals(Event.Stalled, monitor.at(1013.0, 5.0, playing = false))
    }

    @Test
    fun startupNeedsActualVideoAndFailureIsImmediate() {
        val monitor = PlaybackHealthMonitor(0.0)
        assertNull(monitor.at(19.0, 19.0, playing = true, ready = false))
        assertEquals(Event.Stalled, monitor.at(20.0, 20.0, playing = true, ready = false))
        val failed = PlaybackHealthMonitor(0.0)
        assertEquals(Event.Stalled, failed.at(1.0, Double.NaN, playing = false, paused = true, ready = false, failed = true))
    }
}
