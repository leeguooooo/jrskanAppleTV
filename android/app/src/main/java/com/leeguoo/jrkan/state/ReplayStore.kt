package com.leeguoo.jrkan.state

import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.MatchSchedule
import com.leeguoo.jrkan.data.MatchStatus
import com.leeguoo.jrkan.data.ReplayGroup
import com.leeguoo.jrkan.data.ReplayCache
import com.leeguoo.jrkan.data.ReplayParsing
import com.leeguoo.jrkan.data.ReplayVideo
import com.leeguoo.jrkan.data.WeiboClient
import com.leeguoo.jrkan.data.userMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The 回看 list (ReplayLibrary in ReplayStore.swift): recent recordings from
 * the configured uploaders' feeds, grouped by game. Memory only; refetched
 * when ten minutes old.
 */
object ReplayLibrary {
    data class State(val groups: List<ReplayGroup> = emptyList(), val isLoading: Boolean = false, val errorMessage: String? = null)

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state
    val client = WeiboClient()
    private var lastLoad = 0L

    val videos: List<ReplayVideo> get() = _state.value.groups.flatMap { it.videos }


    fun group(id: String): ReplayGroup? = _state.value.groups.firstOrNull { it.id == id }

    suspend fun refreshIfStale(now: Long = System.currentTimeMillis()) {
        // Last time's list shows at once; a stale one is refreshed behind it.
        if (_state.value.groups.isEmpty()) {
            ReplayCache.read("library", ReplayCache.videoList)?.let { hit ->
                lastLoad = hit.savedAt
                _state.value = _state.value.copy(groups = ReplayParsing.groups(hit.value))
            }
        }
        if (lastLoad != 0L && now - lastLoad < ReplayCache.LIBRARY_LIFETIME && _state.value.groups.isNotEmpty()) return
        refresh()
    }

    suspend fun refresh() {
        if (_state.value.isLoading) return
        val config = AppConfigStore.config.value.replay
        if (!config.enabled) { _state.value = State(); return }
        _state.value = _state.value.copy(isLoading = true)
        val rules = config.rules
        // Two pages per uploader reach back about three days for the busier ones.
        val results = coroutineScope {
            config.uploaders.map { uid ->
                async {
                    runCatching {
                        val first = ReplayParsing.waterfall(client.uploaderVideos(uid), rules)
                        val second = first.nextCursor?.let { cursor ->
                            runCatching { ReplayParsing.waterfall(client.uploaderVideos(uid, cursor), rules) }.getOrNull()
                        }
                        first.videos + second?.videos.orEmpty()
                    }
                }
            }.awaitAll()
        }
        val videos = results.flatMap { it.getOrNull().orEmpty() }
        val failure = results.firstNotNullOfOrNull { it.exceptionOrNull() }
        _state.value = if (videos.isEmpty() && failure != null) {
            _state.value.copy(isLoading = false, errorMessage = failure.userMessage())
        } else {
            lastLoad = System.currentTimeMillis()
            ReplayCache.write("library", videos, ReplayCache.videoList)
            State(groups = ReplayParsing.groups(videos))
        }
    }
}

/**
 * Recordings of one match (MatchReplays in ReplayStore.swift): a Weibo search
 * for "主队vs客队 回放" plus the 回看 list, filtered by both teams and kickoff.
 */
class MatchReplays(val match: LiveMatch) {
    sealed interface State {
        data object Idle : State
        data object Loading : State
        data class Loaded(val videos: List<ReplayVideo>) : State
        data class Failed(val message: String) : State
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state

    suspend fun load(now: Long = System.currentTimeMillis()) {
        if (_state.value == State.Loading || !isEligible(match, now)) return
        val kickoff = MatchSchedule.kickoff(match.time, now)?.toEpochMilli() ?: return
        val config = AppConfigStore.config.value.replay
        val known = ReplayLibrary.videos
        val key = ReplayCache.searchKey(match.homeTeam, match.awayTeam, kickoff)
        // A search that is still good is used as is; an older one shows while the new search runs.
        val cached = ReplayCache.read(key, ReplayCache.videoList)
        if (cached != null) {
            _state.value = State.Loaded(ReplayParsing.videos(match.homeTeam, match.awayTeam, kickoff, cached.value + known, config.rules))
            if (now - cached.savedAt < ReplayCache.searchLifetime(kickoff, cached.value.isNotEmpty(), now)) return
        } else {
            _state.value = State.Loading
        }
        val shown = _state.value
        _state.value = try {
            // Uploaders write either order and Weibo ranks them apart: ask both ways.
            val queries = listOf(
                "${match.homeTeam}vs${match.awayTeam}${config.searchSuffix}",
                "${match.awayTeam}vs${match.homeTeam}${config.searchSuffix}",
            )
            val results = coroutineScope {
                queries.map { query ->
                    async { runCatching { ReplayParsing.search(ReplayLibrary.client.searchVideos(query), config.rules) } }
                }.awaitAll()
            }
            if (results.all { it.isFailure }) throw results.first().exceptionOrNull()!!
            val found = results.flatMap { it.getOrNull().orEmpty() }
            val matched = ReplayParsing.videos(match.homeTeam, match.awayTeam, kickoff, found, config.rules)
            ReplayCache.write(key, matched, ReplayCache.videoList)
            State.Loaded(ReplayParsing.videos(match.homeTeam, match.awayTeam, kickoff, matched + known, config.rules))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            // Keep what the cache showed; only an empty screen becomes an error.
            if (shown is State.Loaded && shown.videos.isNotEmpty()) return
            val fallback = ReplayParsing.videos(match.homeTeam, match.awayTeam, kickoff, known, config.rules)
            if (fallback.isEmpty()) State.Failed(error.userMessage()) else State.Loaded(fallback)
        }
    }

    companion object {
        /** Over per the provider, never while live, else a game's usual length after kickoff. */
        fun isEligible(match: LiveMatch, now: Long = System.currentTimeMillis()): Boolean {
            if (!AppConfigStore.config.value.replay.enabled) return false
            val kickoff = MatchSchedule.kickoff(match.time, now)?.toEpochMilli() ?: return false
            val status = MatchSchedule.status(match, now)
            if (status == MatchStatus.Finished) return true
            if (status.isLive) return false
            return now - kickoff > 150 * 60_000L
        }
    }
}
