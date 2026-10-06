package com.leeguoo.jrkan.data

import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max

/**
 * Kotlin port of App/Sources/Shared/Models.swift. Field names, rules and
 * Chinese copy follow the Swift original so both apps behave the same; when
 * the site changes, fix both and keep the shared tests in step.
 */
@Serializable
data class LiveMatch(
    val id: String,
    val league: String,
    val time: String,
    val homeTeam: String,
    val awayTeam: String,
    val homeLogoUrl: String?,
    val awayLogoUrl: String?,
    val isHot: Boolean,
    val sources: List<MatchSource>,
    val providerState: ProviderMatchState? = null,
) {
    val scoreText: String? get() = providerState?.scoreText

    /** Sport code from the listing id, e.g. "4644105,1,4644105" → 1. */
    val listingSportCode: Int?
        get() {
            val parts = id.split(",")
            return if (parts.size == 3) parts[1].toIntOrNull() else null
        }
}

@Serializable
data class MatchSource(
    val id: String,
    val name: String,
    val pageUrl: String,
)

/** Status codes and period clocks used by jrs03.com's page.live script. */
@Serializable
data class ProviderMatchState(
    val sportId: Int,
    val code: Int,
    /** Epoch milliseconds. */
    val periodStartedAt: Long,
    /** Epoch milliseconds. */
    val updatedAt: Long,
    val matchType: Int = 0,
    val homeScore: Int? = null,
    val awayScore: Int? = null,
    val homeHalfScore: Int? = null,
    val awayHalfScore: Int? = null,
    val homeCorners: Int? = null,
    val awayCorners: Int? = null,
) {
    val halftimeText: String?
        get() {
            // hs1/hs2 are football fields. The site's basketball columns show
            // score difference and total, not the zero-filled hs placeholders.
            if (sportId != 1 || code !in 2..7) return null
            return pair(homeHalfScore, awayHalfScore)
        }

    val basketballSummary: Pair<Int, Int>?
        get() {
            if (sportId != 2 || scoreText == null) return null
            val home = homeScore ?: return null
            val away = awayScore ?: return null
            return abs(home - away) to (home + away)
        }

    val cornersText: String?
        get() = if (sportId != 1 || code == 0) null else pair(homeCorners, awayCorners)

    val scoreText: String?
        get() {
            val home = homeScore ?: return null
            val away = awayScore ?: return null
            if (code == 0 || home < 0 || away < 0) return null
            return "$home - $away"
        }

    private fun pair(home: Int?, away: Int?): String? {
        if (home == null || away == null || home < 0 || away < 0) return null
        return "$home - $away"
    }

    fun status(nowMillis: Long): MatchStatus? {
        // Do not keep an old live label indefinitely after a refresh failure.
        if (nowMillis - updatedAt >= 10 * 60_000L || updatedAt - nowMillis >= 5 * 60_000L) return null
        if (code == 0) return MatchStatus.Scheduled
        if (sportId == 1) {
            return when (code) {
                1, 3 -> {
                    val elapsed = max(0L, (nowMillis - periodStartedAt) / 60_000L).toInt()
                    val minute = if (code == 1) elapsed else max(46, elapsed + 45)
                    val limit = if (code == 1) 45 else 90
                    MatchStatus.Live(if (minute > limit) "$limit+" else "$minute′")
                }
                2 -> MatchStatus.Live("中场休息")
                4, 5 -> MatchStatus.Live("加时赛")
                6 -> MatchStatus.Live("点球大战")
                7 -> MatchStatus.Finished
                8 -> MatchStatus.Interrupted("推迟")
                9 -> MatchStatus.Interrupted("中断")
                10 -> MatchStatus.Interrupted("腰斩")
                11 -> MatchStatus.Interrupted("取消")
                12 -> MatchStatus.Interrupted("待定")
                else -> null
            }
        }
        if (sportId == 2) {
            // The website adjusts period labels for two-half competitions.
            val periodCode = if (matchType == 2 && (code == 4 || code == 8)) code / 2 else code
            val periods = mapOf(
                1 to "第一节", 2 to "第一节结束", 3 to "第二节", 4 to "第二节结束",
                5 to "第三节", 6 to "第三节结束", 7 to "第四节", 8 to "加时",
            )
            periods[periodCode]?.let { return MatchStatus.Live(it) }
            return when (code) {
                9 -> MatchStatus.Finished
                10 -> MatchStatus.Interrupted("中断")
                11 -> MatchStatus.Interrupted("取消")
                12 -> MatchStatus.Interrupted("推迟")
                13 -> MatchStatus.Interrupted("腰斩")
                14 -> MatchStatus.Interrupted("待定")
                else -> null
            }
        }
        return null
    }
}

/** Provider-confirmed match state, with scheduled countdowns when appropriate. */
sealed interface MatchStatus {
    data class Live(val label: String) : MatchStatus
    data class Upcoming(val startsInMinutes: Int) : MatchStatus
    data object Scheduled : MatchStatus
    data class Interrupted(val label: String) : MatchStatus
    data object Finished : MatchStatus
    data object Unknown : MatchStatus

    val isLive: Boolean get() = this is Live

    /** Sort key: what's on now first, then what's next, then what's over. */
    val rank: Int
        get() = when (this) {
            is Live -> 0
            is Upcoming, Scheduled -> 1
            Unknown, is Interrupted -> 2
            Finished -> 3
        }

    val sectionTitle: String
        get() = when (this) {
            is Live -> "正在进行"
            is Upcoming, Scheduled -> "未开赛"
            Unknown, is Interrupted -> "其他"
            Finished -> "已结束"
        }
}

/**
 * Schedule times are used for display and upcoming countdowns only.
 * In-progress and final states come from the website's event feed.
 */
object MatchSchedule {
    val feedZone: ZoneId = ZoneId.of("Asia/Shanghai")

    /** League-name fallback for rows that carry no sport code. */
    fun isBasketball(league: String): Boolean =
        SportFilter.basketballLeagues.any { league.contains(it, ignoreCase = true) }

    /**
     * The listing's `data-lid` ("<id>,<sport>,<id>") carries the site's sport
     * code, the same value its own menu filters on: 1 football, 2 basketball,
     * 131 badminton. The league name covers rows from an older markup.
     */
    fun isBadminton(match: LiveMatch): Boolean {
        if (match.listingSportCode == 131) return true
        return listOf("羽毛球", "羽球", "BWF").any { match.league.contains(it, ignoreCase = true) }
    }

    /** "MM-dd HH:mm" in Beijing time → instant, picking the year nearest `now`. */
    fun kickoff(raw: String, nowMillis: Long = System.currentTimeMillis()): Instant? {
        val parts = raw.split(' ', ' ').filter { it.isNotEmpty() }
        if (parts.size != 2) return null
        val day = parts[0].split("-").mapNotNull { it.toIntOrNull() }
        val clock = parts[1].split(":").mapNotNull { it.toIntOrNull() }
        if (day.size != 2 || clock.size != 2) return null
        val now = Instant.ofEpochMilli(nowMillis)
        val year = now.atZone(feedZone).year
        var date = try {
            ZonedDateTime.of(year, day[0], day[1], clock[0], clock[1], 0, 0, feedZone)
        } catch (_: Exception) {
            return null
        }
        // No year in the feed. Around New Year the naive guess lands a whole
        // year off, so snap to whichever year puts the date closest to today.
        val halfYear = 182L * 24 * 60 * 60 * 1000
        val delta = date.toInstant().toEpochMilli() - nowMillis
        if (delta > halfYear) date = date.minusYears(1)
        else if (-delta > halfYear) date = date.plusYears(1)
        return date.toInstant()
    }

    fun status(match: LiveMatch, nowMillis: Long = System.currentTimeMillis()): MatchStatus {
        val provided = match.providerState?.status(nowMillis)
        if (provided != null) {
            if (provided == MatchStatus.Scheduled) {
                val kickoff = kickoff(match.time, nowMillis)
                if (kickoff != null && kickoff.toEpochMilli() > nowMillis) {
                    return MatchStatus.Upcoming(minutesUntil(kickoff.toEpochMilli(), nowMillis))
                }
            }
            return provided
        }
        return status(match.time, nowMillis)
    }

    fun status(raw: String, nowMillis: Long = System.currentTimeMillis()): MatchStatus {
        val kickoff = kickoff(raw, nowMillis) ?: return MatchStatus.Unknown
        if (kickoff.toEpochMilli() > nowMillis) {
            return MatchStatus.Upcoming(minutesUntil(kickoff.toEpochMilli(), nowMillis))
        }
        return MatchStatus.Unknown
    }

    private fun minutesUntil(target: Long, now: Long): Int = ceil((target - now) / 60_000.0).toInt()

    data class DisplayTime(val day: String, val clock: String)

    /**
     * Kickoff rendered in the viewer's own zone: a relative day word plus the
     * clock, measured against the caller's `now` rather than the system clock.
     */
    fun displayTime(
        raw: String,
        nowMillis: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): DisplayTime {
        val kickoff = kickoff(raw, nowMillis)
        if (kickoff == null) {
            val parts = raw.split(" ", limit = 2)
            return if (parts.size == 2) DisplayTime(parts[0], parts[1]) else DisplayTime("", raw)
        }
        val local = kickoff.atZone(zone)
        val clock = local.format(DateTimeFormatter.ofPattern("HH:mm", Locale.CHINA))
        val today: LocalDate = Instant.ofEpochMilli(nowMillis).atZone(zone).toLocalDate()
        val day = when (ChronoUnit.DAYS.between(today, local.toLocalDate())) {
            0L -> "今天"
            1L -> "明天"
            -1L -> "昨天"
            else -> local.format(DateTimeFormatter.ofPattern("M月d日", Locale.CHINA))
        }
        return DisplayTime(day, clock)
    }

    /** True when the device is not on Beijing time. */
    fun viewerIsOffFeedTime(zone: ZoneId = ZoneId.systemDefault(), nowMillis: Long = System.currentTimeMillis()): Boolean {
        val now = Instant.ofEpochMilli(nowMillis)
        return zone.rules.getOffset(now) != feedZone.rules.getOffset(now)
    }
}

enum class SportFilter(val title: String) {
    // Declaration order is display order: everything first, then the two
    // sports watched most.
    All("全部"),
    Basketball("篮球"),
    Badminton("羽毛球"),
    Football("足球"),
    Hot("热门"),
    Followed("关注"),
    Recent("最近观看");

    fun includes(match: LiveMatch, favorites: Set<String> = emptySet()): Boolean = when (this) {
        All -> true
        Recent -> false // The list model uses the saved match snapshots for this filter.
        Followed -> match.homeTeam in favorites || match.awayTeam in favorites
        Hot -> match.isHot
        Basketball -> {
            // Sport code 2 is basketball both in the listing id and the event
            // feed; the league name only covers rows that carry neither.
            val code = match.providerState?.sportId ?: match.listingSportCode
            if (code != null) code == 2 else MatchSchedule.isBasketball(match.league)
        }
        Badminton -> MatchSchedule.isBadminton(match)
        Football -> !Basketball.includes(match) && !Badminton.includes(match)
    }

    companion object {
        /** The sports that get a tab of their own; the rest refine 全部. */
        val tabs = listOf(All, Basketball, Badminton, Football)

        val basketballLeagues = listOf("NBA", "WNBA", "CBA", "NBL", "篮", "篮球", "欧篮", "韩篮", "菲MPBL")

        fun fromTitle(title: String?): SportFilter? = entries.firstOrNull { it.title == title }
    }
}
