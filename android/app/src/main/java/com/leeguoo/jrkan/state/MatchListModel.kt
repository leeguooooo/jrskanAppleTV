package com.leeguoo.jrkan.state

import com.leeguoo.jrkan.data.EventSnapshot
import com.leeguoo.jrkan.data.JrsClient
import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.MatchSchedule
import com.leeguoo.jrkan.data.MatchStatus
import com.leeguoo.jrkan.data.SportFilter
import com.leeguoo.jrkan.data.userMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.min
import kotlin.math.pow

data class MatchSection(val status: MatchStatus, val matches: List<LiveMatch>, val titleOverride: String? = null) {
    val id: Int get() = status.rank
    val title: String get() = titleOverride ?: status.sectionTitle
}

/**
 * The schedule, its live scores and how they refresh. Port of
 * App/Sources/Shared/MatchListModel.swift; one instance for the whole app.
 */
class MatchListModel(
    val preferences: Preferences,
    private val scope: CoroutineScope,
    private val client: JrsClient = JrsClient(),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    data class State(
        val matches: List<LiveMatch> = emptyList(),
        val isLoading: Boolean = false,
        val lastUpdated: Long? = null,
        val scoresUpdatedAt: Long? = null,
        val scoreNotice: String? = null,
        val isRefreshingScores: Boolean = false,
        val errorMessage: String? = null,
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state

    private val _filter = MutableStateFlow(
        preferences.lastFilter.value.let {
            if (it == SportFilter.Recent && preferences.recentWatches.value.isEmpty()) SportFilter.All else it
        }
    )
    val filter: StateFlow<SportFilter> = _filter

    private val _searchText = MutableStateFlow("")
    val searchText: StateFlow<String> = _searchText

    private var scheduleMatches: List<LiveMatch> = emptyList()
    private var eventUrl: String? = null
    private var scoreFailures = 0
    private var lastScoreAttempt: Long? = null
    private var autoRefreshJob: Job? = null
    private var refreshJob: Job? = null

    fun setFilter(value: SportFilter) {
        _filter.value = value
        preferences.setLastFilter(value)
    }

    fun setSearchText(value: String) {
        _searchText.value = value
    }

    // Loading

    fun loadIfNeeded() {
        if (_state.value.matches.isEmpty()) refresh()
    }

    /** Foreground return: only re-fetch when the data is old enough to matter. */
    fun refreshIfStale(maxAgeMillis: Long = 120_000) {
        val state = _state.value
        val now = clock()
        if (state.lastUpdated != null && now - state.lastUpdated < maxAgeMillis) {
            if (state.scoresUpdatedAt == null || now - state.scoresUpdatedAt >= SCORE_INTERVAL) {
                scope.launch { refreshScores() }
            }
        } else refresh()
    }

    fun refresh(): Job {
        refreshJob?.takeIf { it.isActive }?.let { return it }
        return scope.launch { refreshNow() }.also { refreshJob = it }
    }

    suspend fun refreshNow() {
        if (_state.value.isLoading) return
        _state.update { it.copy(isLoading = true, errorMessage = null) }
        try {
            val schedule = client.fetchSchedule()
            scheduleMatches = schedule.matches
            schedule.eventUrl?.let { eventUrl = it }
            // Keep the last known scores while the independent event request runs
            // or fails. Their source timestamp does not change with the schedule.
            val previous = _state.value.matches.mapNotNull { m -> m.providerState?.let { m.id to it } }.toMap()
            _state.update { state ->
                state.copy(
                    matches = scheduleMatches.map { it.copy(providerState = previous[it.id]) },
                    lastUpdated = clock(),
                    isLoading = false,
                )
            }
        } catch (e: CancellationException) {
            _state.update { it.copy(isLoading = false) }
            throw e
        } catch (e: Exception) {
            _state.update { it.copy(isLoading = false, errorMessage = e.userMessage()) }
        }
        refreshScores()
    }

    suspend fun refreshScores() {
        if (_state.value.isRefreshingScores) return
        val url = eventUrl
        if (url == null) {
            _state.update { it.copy(scoreNotice = "比分暂不可用") }
            return
        }
        _state.update { it.copy(isRefreshingScores = true) }
        lastScoreAttempt = clock()
        try {
            val snapshot: EventSnapshot = client.fetchEvents(url)
            val known = _state.value.scoresUpdatedAt
            // An older CDN response must not overwrite a newer score snapshot.
            if (known == null || snapshot.updatedAt >= known) {
                _state.update {
                    it.copy(
                        matches = snapshot.applying(scheduleMatches),
                        scoresUpdatedAt = snapshot.updatedAt,
                        scoreNotice = null,
                    )
                }
                scoreFailures = 0
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            scoreFailures += 1
            _state.update {
                it.copy(scoreNotice = if (it.scoresUpdatedAt == null) "比分暂不可用" else "比分更新失败，显示上次数据")
            }
        } finally {
            _state.update { it.copy(isRefreshingScores = false) }
        }
    }

    fun startAutoRefresh() {
        if (autoRefreshJob?.isActive == true) return
        autoRefreshJob = scope.launch {
            while (isActive) {
                delay(SCORE_INTERVAL)
                if (!preferences.autoRefresh.value) continue
                val now = clock()
                val lastUpdated = _state.value.lastUpdated
                if (lastUpdated == null || now - lastUpdated >= AUTO_REFRESH_INTERVAL) {
                    refreshNow()
                } else {
                    val backoff = min(AUTO_REFRESH_INTERVAL.toDouble(), SCORE_INTERVAL * 2.0.pow(min(scoreFailures, 4)))
                    val attempt = lastScoreAttempt
                    if (attempt == null || now - attempt >= backoff) refreshScores()
                }
            }
        }
    }

    fun stopAutoRefresh() {
        autoRefreshJob?.cancel()
        autoRefreshJob = null
    }

    // Derived lists

    fun recentMatches(matches: List<LiveMatch> = _state.value.matches): List<LiveMatch> =
        preferences.recentWatches.value.map { saved -> matches.firstOrNull { it.id == saved.match.id } ?: saved.match }

    fun continueMatch(matches: List<LiveMatch> = _state.value.matches): LiveMatch? =
        recentMatches(matches).firstOrNull { recent ->
            matches.any { it.id == recent.id } && recent.sources.isNotEmpty() &&
                MatchSchedule.status(recent, clock()) != MatchStatus.Finished
        }

    fun filteredMatches(
        matches: List<LiveMatch> = _state.value.matches,
        filter: SportFilter = _filter.value,
        favorites: Set<String> = preferences.favoriteTeams.value,
    ): List<LiveMatch> {
        if (filter == SportFilter.Recent) return recentMatches(matches)
        return sorted(matches).filter { filter.includes(it, favorites) }
    }

    fun visibleMatches(matches: List<LiveMatch> = _state.value.matches, query: String = _searchText.value): List<LiveMatch> =
        sorted(matches).filter {
            query.isEmpty() || it.league.contains(query, true) || it.homeTeam.contains(query, true) ||
                it.awayTeam.contains(query, true)
        }

    /** The current filter split into "on now / up next / over" groups. */
    fun sections(
        matches: List<LiveMatch> = _state.value.matches,
        filter: SportFilter = _filter.value,
        favorites: Set<String> = preferences.favoriteTeams.value,
    ): List<MatchSection> {
        if (filter == SportFilter.Recent) {
            val recent = recentMatches(matches)
            return if (recent.isEmpty()) emptyList() else listOf(MatchSection(MatchStatus.Unknown, recent, "最近观看"))
        }
        val now = clock()
        return filteredMatches(matches, filter, favorites)
            .groupBy { MatchSchedule.status(it, now).rank }
            .toSortedMap()
            .map { (_, group) -> MatchSection(MatchSchedule.status(group.first(), now), group) }
    }

    /** Which refinements to offer: 关注 / 最近观看 only once there is something in them. */
    fun availableFilters(): List<SportFilter> = SportFilter.entries.filter {
        (it != SportFilter.Followed || preferences.favoriteTeams.value.isNotEmpty()) &&
            (it != SportFilter.Recent || preferences.recentWatches.value.isNotEmpty())
    }

    fun categoryCount(filter: SportFilter, matches: List<LiveMatch> = _state.value.matches): Int =
        if (filter == SportFilter.Recent) recentMatches(matches).size
        else matches.count { filter.includes(it, preferences.favoriteTeams.value) }

    fun leagueNames(matches: List<LiveMatch> = _state.value.matches): List<String> = matches.map { it.league }.distinct()

    /** Live first, then upcoming by kickoff, then finished (latest first). */
    private fun sorted(matches: List<LiveMatch>): List<LiveMatch> {
        val now = clock()
        data class Keyed(val match: LiveMatch, val status: MatchStatus, val kickoff: Long)
        val keyed = matches.map {
            Keyed(it, MatchSchedule.status(it, now), MatchSchedule.kickoff(it.time, now)?.toEpochMilli() ?: Long.MAX_VALUE)
        }
        return keyed.sortedWith { l, r ->
            when {
                l.status.rank != r.status.rank -> l.status.rank.compareTo(r.status.rank)
                // A live match with no channel cannot be watched; keep playable ones first.
                l.match.sources.isNotEmpty() != r.match.sources.isNotEmpty() -> if (l.match.sources.isNotEmpty()) -1 else 1
                l.status == MatchStatus.Finished -> r.kickoff.compareTo(l.kickoff)
                else -> l.kickoff.compareTo(r.kickoff)
            }
        }.map { it.match }
    }

    companion object {
        const val AUTO_REFRESH_INTERVAL = 5 * 60_000L
        const val SCORE_INTERVAL = 30_000L
    }
}
