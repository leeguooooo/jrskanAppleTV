package com.leeguoo.jrkan.state

import android.content.Context
import android.content.SharedPreferences
import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.MatchSource
import com.leeguoo.jrkan.data.SportFilter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Everything the app remembers between launches, kept in app-private
 * SharedPreferences. Port of App/Sources/Shared/Preferences.swift: same
 * retention windows, same channel ranking.
 */
class Preferences(private val store: SharedPreferences, private val clock: () -> Long = System::currentTimeMillis) {

    @Serializable
    data class LastChannel(val name: String, val index: Int, val watchedAt: Long)

    @Serializable
    data class RecentWatch(val match: LiveMatch, val channelName: String, val watchedAt: Long) {
        val id: String get() = match.id
    }

    @Serializable
    data class ChannelPerformance(
        val successes: Int = 0,
        val failures: Int = 0,
        val averageStartup: Double = 20.0,
        val lastFailure: Long? = null,
        val updatedAt: Long = 0,
    ) {
        val reliability: Double get() = (successes + 1).toDouble() / (successes + failures + 2)
    }

    private val json = Json { ignoreUnknownKeys = true }

    private val _favoriteTeams = MutableStateFlow(store.getStringSet(FAVORITES, emptySet())!!.toSet())
    val favoriteTeams: StateFlow<Set<String>> = _favoriteTeams

    private val _autoRefresh = MutableStateFlow(store.getBoolean(AUTO_REFRESH, true))
    val autoRefresh: StateFlow<Boolean> = _autoRefresh

    private val _autoNextChannel = MutableStateFlow(store.getBoolean(AUTO_NEXT, true))
    val autoNextChannel: StateFlow<Boolean> = _autoNextChannel

    private val _lastFilter = MutableStateFlow(SportFilter.fromTitle(store.getString(LAST_FILTER, null)) ?: SportFilter.All)
    val lastFilter: StateFlow<SportFilter> = _lastFilter

    private val _lastChannels = MutableStateFlow(
        // Match IDs are per fixture; anything older than a week is long over.
        decode<Map<String, LastChannel>>(LAST_CHANNELS).orEmpty()
            .filterValues { clock() - it.watchedAt < WEEK }
    )
    val lastChannels: StateFlow<Map<String, LastChannel>> = _lastChannels

    private val _recentWatches = MutableStateFlow(
        decode<List<RecentWatch>>(RECENT).orEmpty().filter { clock() - it.watchedAt < WEEK }.take(10)
    )
    val recentWatches: StateFlow<List<RecentWatch>> = _recentWatches

    private val _channelPerformance = MutableStateFlow(
        decode<Map<String, ChannelPerformance>>(PERFORMANCE).orEmpty().filterValues { clock() - it.updatedAt < MONTH }
    )
    val channelPerformance: StateFlow<Map<String, ChannelPerformance>> = _channelPerformance

    // Settings

    fun setAutoRefresh(value: Boolean) {
        _autoRefresh.value = value
        store.edit().putBoolean(AUTO_REFRESH, value).apply()
    }

    fun setAutoNextChannel(value: Boolean) {
        _autoNextChannel.value = value
        store.edit().putBoolean(AUTO_NEXT, value).apply()
    }

    fun setLastFilter(value: SportFilter) {
        _lastFilter.value = value
        store.edit().putString(LAST_FILTER, value.title).apply()
    }

    // Favorites

    fun isFavorite(team: String) = team in _favoriteTeams.value

    fun toggleFavorite(team: String) {
        val next = _favoriteTeams.value.toMutableSet().apply { if (!remove(team)) add(team) }
        _favoriteTeams.value = next
        store.edit().putStringSet(FAVORITES, next).apply()
    }

    fun follows(match: LiveMatch, favorites: Set<String> = _favoriteTeams.value) =
        match.homeTeam in favorites || match.awayTeam in favorites

    // Watch history

    fun lastChannel(matchId: String): LastChannel? = _lastChannels.value[matchId]

    fun recordPlaybackSuccess(match: LiveMatch, source: MatchSource, index: Int, startupSeconds: Double, now: Long = clock()) {
        setLastChannels(_lastChannels.value + (match.id to LastChannel(source.name, index, now)))
        // History never pretends old live data is current.
        val saved = match.copy(providerState = null)
        val recent = _recentWatches.value.filter { it.id != match.id && now - it.watchedAt < WEEK }
        setRecent((listOf(RecentWatch(saved, source.name, now)) + recent).take(10))
        val current = _channelPerformance.value[source.pageUrl] ?: ChannelPerformance()
        val elapsed = startupSeconds.coerceIn(0.0, 120.0)
        val updated = current.copy(
            averageStartup = if (current.successes == 0) elapsed else current.averageStartup * 0.7 + elapsed * 0.3,
            successes = current.successes + 1,
            lastFailure = null,
            updatedAt = now,
        )
        setPerformance(prune(_channelPerformance.value + (source.pageUrl to updated), now))
    }

    fun recordPlaybackFailure(source: MatchSource, now: Long = clock()) {
        val current = _channelPerformance.value[source.pageUrl] ?: ChannelPerformance()
        val updated = current.copy(failures = current.failures + 1, lastFailure = now, updatedAt = now)
        setPerformance(prune(_channelPerformance.value + (source.pageUrl to updated), now))
    }

    private fun prune(map: Map<String, ChannelPerformance>, now: Long) = map
        .filterValues { now - it.updatedAt < MONTH }
        .entries.sortedByDescending { it.value.updatedAt }.take(300)
        .associate { it.key to it.value }

    /** Channel order: cooling-off failures last, then last time's pick, then reliability and speed. */
    fun rankedIndices(sources: List<MatchSource>, matchId: String, now: Long = clock()): List<Int> {
        val performance = _channelPerformance.value
        val last = _lastChannels.value[matchId]?.name
        return sources.indices.sortedWith { lhs, rhs ->
            val a = performance[sources[lhs].pageUrl] ?: ChannelPerformance()
            val b = performance[sources[rhs].pageUrl] ?: ChannelPerformance()
            val aCooling = a.lastFailure?.let { now - it < 300_000 } ?: false
            val bCooling = b.lastFailure?.let { now - it < 300_000 } ?: false
            val aRemembered = a.successes > 0 && sources[lhs].name == last
            val bRemembered = b.successes > 0 && sources[rhs].name == last
            when {
                aCooling != bCooling -> if (aCooling) 1 else -1
                aRemembered != bRemembered -> if (aRemembered) -1 else 1
                a.reliability != b.reliability -> b.reliability.compareTo(a.reliability)
                a.averageStartup != b.averageStartup -> a.averageStartup.compareTo(b.averageStartup)
                else -> lhs.compareTo(rhs)
            }
        }
    }

    val hasHistory: Boolean
        get() = _favoriteTeams.value.isNotEmpty() || _lastChannels.value.isNotEmpty() ||
            _recentWatches.value.isNotEmpty() || _channelPerformance.value.isNotEmpty()

    fun clearHistory() {
        _favoriteTeams.value = emptySet()
        store.edit().remove(FAVORITES).apply()
        setLastChannels(emptyMap())
        setRecent(emptyList())
        setPerformance(emptyMap())
        setLastFilter(SportFilter.All)
    }

    private fun setLastChannels(value: Map<String, LastChannel>) {
        _lastChannels.value = value
        store.edit().putString(LAST_CHANNELS, json.encodeToString(value)).apply()
    }

    private fun setRecent(value: List<RecentWatch>) {
        _recentWatches.value = value
        store.edit().putString(RECENT, json.encodeToString(value)).apply()
    }

    private fun setPerformance(value: Map<String, ChannelPerformance>) {
        _channelPerformance.value = value
        store.edit().putString(PERFORMANCE, json.encodeToString(value)).apply()
    }

    private inline fun <reified T> decode(key: String): T? =
        store.getString(key, null)?.let { runCatching { json.decodeFromString<T>(it) }.getOrNull() }

    companion object {
        private const val FAVORITES = "favoriteTeams"
        private const val AUTO_REFRESH = "autoRefresh"
        private const val AUTO_NEXT = "autoNextChannel"
        private const val LAST_FILTER = "lastFilter"
        private const val LAST_CHANNELS = "lastChannels"
        private const val RECENT = "recentWatches"
        private const val PERFORMANCE = "channelPerformance"
        private const val WEEK = 7L * 86_400_000
        private const val MONTH = 30L * 86_400_000

        fun open(context: Context) = Preferences(context.getSharedPreferences("jrkan", Context.MODE_PRIVATE))
    }
}
