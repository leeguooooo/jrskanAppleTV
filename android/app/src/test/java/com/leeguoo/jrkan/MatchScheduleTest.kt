package com.leeguoo.jrkan

import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.MatchSchedule
import com.leeguoo.jrkan.data.MatchStatus
import com.leeguoo.jrkan.data.ProviderMatchState
import com.leeguoo.jrkan.data.SportFilter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** Port of MatchScheduleTests in App/Tests/MatchScheduleTests.swift. */
class MatchScheduleTest {
    private val beijing = ZoneId.of("Asia/Shanghai")

    private fun date(value: String): Long =
        LocalDateTime.parse(value, DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm"))
            .atZone(beijing).toInstant().toEpochMilli()

    private fun match(id: String, league: String, time: String = "09-05 20:00") = LiveMatch(
        id = id, league = league, time = time, homeTeam = "A", awayTeam = "B",
        homeLogoUrl = null, awayLogoUrl = null, isHot = false, sources = emptyList(),
    )

    @Test
    fun kickoffUsesCurrentYearInBeijingTime() {
        val now = date("2026-09-05 18:00")
        assertEquals(date("2026-09-05 20:00"), MatchSchedule.kickoff("09-05 20:00", now)?.toEpochMilli())
    }

    @Test
    fun kickoffSnapsAcrossNewYear() {
        assertEquals(
            date("2027-01-02 03:00"),
            MatchSchedule.kickoff("01-02 03:00", date("2026-12-31 23:00"))?.toEpochMilli(),
        )
        assertEquals(
            date("2026-12-31 23:00"),
            MatchSchedule.kickoff("12-31 23:00", date("2027-01-01 01:00"))?.toEpochMilli(),
        )
    }

    @Test
    fun statusBuckets() {
        val now = date("2026-09-05 20:30")
        assertEquals(MatchStatus.Unknown, MatchSchedule.status("09-05 20:00", now))
        assertEquals(MatchStatus.Upcoming(45), MatchSchedule.status("09-05 21:15", now))
        assertEquals(MatchStatus.Unknown, MatchSchedule.status("09-05 16:00", now))
        assertEquals(MatchStatus.Unknown, MatchSchedule.status("待定", now))
    }

    @Test
    fun displayTimeConvertsToViewerZone() {
        val now = date("2026-09-05 18:00")
        val shown = MatchSchedule.displayTime("09-05 23:30", now, ZoneId.of("Asia/Tokyo"))
        assertEquals("明天", shown.day)
        assertEquals("00:30", shown.clock)

        val local = MatchSchedule.displayTime("09-05 23:30", now, beijing)
        assertEquals("今天", local.day)
        assertEquals("23:30", local.clock)
    }

    @Test
    fun followedFilterMatchesEitherTeam() {
        val match = LiveMatch(
            id = "1", league = "NBA", time = "09-05 20:00", homeTeam = "湖人", awayTeam = "凯尔特人",
            homeLogoUrl = null, awayLogoUrl = null, isHot = false, sources = emptyList(),
        )
        assertTrue(SportFilter.Followed.includes(match, setOf("凯尔特人")))
        assertFalse(SportFilter.Followed.includes(match, setOf("勇士")))
    }

    @Test
    fun badmintonComesFromListingSportCode() {
        val badminton = match("7001,131,7001", league = "印尼公开赛")
        assertTrue(SportFilter.Badminton.includes(badminton))
        assertFalse(SportFilter.Football.includes(badminton))
        assertTrue(SportFilter.Badminton.includes(match("7002", league = "BWF世界巡回赛")))
        assertFalse(SportFilter.Badminton.includes(match("4644105,1,4644105", league = "蒙古超")))
        val youthBasketball = match("3944800,2,3944800", league = "U18女亚洲杯")
        assertTrue(SportFilter.Basketball.includes(youthBasketball))
        assertFalse(SportFilter.Football.includes(youthBasketball))
        assertEquals(
            listOf(SportFilter.All, SportFilter.Basketball, SportFilter.Badminton, SportFilter.Football),
            SportFilter.tabs,
        )
    }

    @Test
    fun elapsedKickoffNeverProvesLiveOrFinished() {
        val now = date("2026-09-05 22:50")
        for (league in listOf("美职联", "NBA", "未知联赛")) {
            assertEquals(MatchStatus.Unknown, MatchSchedule.status(match("x", league, "09-05 20:30"), now))
        }
    }

    @Test
    fun providerStateOverridesElapsedKickoffForOvertimeAndPostponement() {
        val now = date("2026-09-06 10:30")
        var match = LiveMatch(
            id = "one", league = "美职联", time = "09-06 07:30", homeTeam = "Home", awayTeam = "Away",
            homeLogoUrl = null, awayLogoUrl = null, isHot = false, sources = emptyList(),
        )
        fun state(code: Int, sport: Int = 1) = ProviderMatchState(sportId = sport, code = code, periodStartedAt = now, updatedAt = now)
        match = match.copy(providerState = state(4))
        assertEquals(MatchStatus.Live("加时赛"), MatchSchedule.status(match, now))
        match = match.copy(providerState = state(6))
        assertEquals(MatchStatus.Live("点球大战"), MatchSchedule.status(match, now))
        match = match.copy(providerState = state(8))
        assertEquals(MatchStatus.Interrupted("推迟"), MatchSchedule.status(match, now))
        match = match.copy(providerState = state(7))
        assertEquals(MatchStatus.Finished, MatchSchedule.status(match, now))
        match = match.copy(providerState = state(8, sport = 2))
        assertEquals(MatchStatus.Live("加时"), MatchSchedule.status(match, now))
        match = match.copy(providerState = state(9, sport = 2))
        assertEquals(MatchStatus.Finished, MatchSchedule.status(match, now))
        match = match.copy(providerState = state(0))
        assertEquals(MatchStatus.Scheduled, MatchSchedule.status(match, now))
    }

    @Test
    fun periodClockUsesSecondHalfStartAndExpiresWhenStale() {
        val now = date("2026-09-06 10:30")
        val state = ProviderMatchState(sportId = 1, code = 3, periodStartedAt = now - 8 * 60_000, updatedAt = now)
        assertEquals(MatchStatus.Live("53′"), state.status(now))
        assertNull(state.status(now + 10 * 60_000))
        val stoppage = ProviderMatchState(sportId = 1, code = 3, periodStartedAt = now - 51 * 60_000, updatedAt = now)
        assertEquals(MatchStatus.Live("90+"), stoppage.status(now))
        assertEquals(
            MatchStatus.Live("中场休息"),
            ProviderMatchState(sportId = 1, code = 2, periodStartedAt = now, updatedAt = now).status(now),
        )
    }

    /** The ProviderMatchState assertions from ExperienceTests.testStatisticsAndContinueUseLatestEventSnapshot. */
    @Test
    fun derivedStatisticsTexts() {
        val now = System.currentTimeMillis()
        val firstHalf = ProviderMatchState(
            sportId = 1, code = 1, periodStartedAt = now, updatedAt = now,
            homeHalfScore = 1, awayHalfScore = 0, homeCorners = -1, awayCorners = 0,
        )
        assertNull(firstHalf.halftimeText)
        assertNull(firstHalf.cornersText)
        val basketball = ProviderMatchState(
            sportId = 2, code = 5, periodStartedAt = now, updatedAt = now,
            homeScore = 54, awayScore = 58, homeHalfScore = 0, awayHalfScore = 0,
        )
        assertNull(basketball.halftimeText)
        assertEquals(4 to 112, basketball.basketballSummary)
    }
}
