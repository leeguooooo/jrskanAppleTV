package com.leeguoo.jrkan

import android.content.SharedPreferences
import com.leeguoo.jrkan.data.JrsClient
import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.MatchSource
import com.leeguoo.jrkan.data.ProviderMatchState
import com.leeguoo.jrkan.data.SourcePageClient
import com.leeguoo.jrkan.data.SportFilter
import com.leeguoo.jrkan.data.StreamResolver
import com.leeguoo.jrkan.state.MatchListModel
import com.leeguoo.jrkan.state.MatchPlaybackModel
import com.leeguoo.jrkan.state.Preferences
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.ConcurrentHashMap

/**
 * Port of the Preferences / MatchPlaybackModel / MatchListModel cases in
 * App/Tests/ExperienceTests.swift.
 */
class ExperienceTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @After
    fun tearDown() = scope.cancel()

    private fun source(index: Int) = MatchSource("s$index", "Line $index", "https://experience.example/$index.m3u8")

    private fun match(id: String = "match") = LiveMatch(
        id = id, league = "League", time = "09-06 12:00", homeTeam = "Home", awayTeam = "Away",
        homeLogoUrl = null, awayLogoUrl = null, isHot = false, sources = listOf(source(0), source(1)),
    )

    /** Every stream answers as a valid playlist, like the Swift ExperienceProtocol default. */
    private val streams: OkHttpClient = fixtureClient { FixtureReply("#EXTM3U\n#EXTINF:5,\nsegment.ts\n") }

    private fun waitUntil(predicate: () -> Boolean) {
        repeat(300) {
            if (predicate()) return
            Thread.sleep(10)
        }
        throw AssertionError("Asynchronous playback transition did not complete")
    }

    @Test
    fun rankingUsesSuccessLatencyAndTemporaryFailureCooldown() {
        val prefs = Preferences(MemoryPreferences())
        val sources = listOf(source(0), source(1), source(2))
        prefs.recordPlaybackFailure(sources[0])
        assertEquals(1, prefs.rankedIndices(sources, "new").first())
        prefs.recordPlaybackSuccess(match("a"), sources[1], 1, 8.0)
        prefs.recordPlaybackSuccess(match("b"), sources[2], 2, 2.0)
        assertEquals(2, prefs.rankedIndices(sources, "new").first())
        assertEquals(1, prefs.rankedIndices(sources, "a").first())
        prefs.recordPlaybackFailure(sources[1])
        assertEquals(2, prefs.rankedIndices(sources, "a").first())
    }

    @Test
    fun historyPersistsOnlyMatchEntrancesAndIsBoundedAndClearable() {
        val store = MemoryPreferences()
        val prefs = Preferences(store)
        val now = System.currentTimeMillis()
        repeat(12) { index ->
            val item = match("$index").copy(providerState = ProviderMatchState(1, 3, now, now))
            prefs.recordPlaybackSuccess(item, source(0), 0, 1.0)
        }
        val restored = Preferences(store)
        assertEquals(10, restored.recentWatches.value.size)
        assertEquals("11", restored.recentWatches.value.first().id)
        assertNull(restored.recentWatches.value.first().match.providerState)
        assertEquals(match().sources, restored.recentWatches.value.first().match.sources)
        restored.clearHistory()
        assertFalse(restored.hasHistory)
        assertTrue(Preferences(store).recentWatches.value.isEmpty())
    }

    @Test
    fun resolutionAloneDoesNotCreateHistoryAndConfirmedCallbacksAreIdempotent() {
        val prefs = Preferences(MemoryPreferences())
        val model = MatchPlaybackModel(match(), prefs, scope, StreamResolver(streams), SourcePageClient(streams))
        model.startPlayback(0)
        waitUntil { model.state.value.playback != null }
        assertTrue(prefs.recentWatches.value.isEmpty())
        assertNull(prefs.lastChannel(match().id))
        model.confirmPlayback("someone-else", 1.0)
        assertTrue(prefs.recentWatches.value.isEmpty())
        val id = model.state.value.playback!!.id
        model.confirmPlayback(id, 1.0)
        model.confirmPlayback(id, 1.0)
        assertEquals(1, prefs.recentWatches.value.size)
        assertEquals(1, prefs.channelPerformance.value[source(0).pageUrl]?.successes)
        model.stopPlayback()
    }

    @Test
    fun midstreamFailureReconnectsOnceThenSwitchesAndIgnoresOldCallbacks() {
        val prefs = Preferences(MemoryPreferences())
        val model = MatchPlaybackModel(match(), prefs, scope, StreamResolver(streams), SourcePageClient(streams))
        model.startPlayback(0)
        waitUntil { model.state.value.playback != null }
        val first = model.state.value.playback!!
        model.confirmPlayback(first.id, 1.0)
        val now = System.currentTimeMillis()
        model.handleStall("Disconnected", first.id, now)
        waitUntil { model.state.value.playback?.id.let { it != null && it != first.id } }
        val reconnected = model.state.value.playback!!
        assertEquals(0, reconnected.index)
        model.confirmPlayback(reconnected.id, 1.0)
        model.handleStall("Disconnected again", reconnected.id, now + 10_000)
        waitUntil { model.state.value.playback?.index == 1 }
        val next = model.state.value.playback!!
        model.handleStall("Late old event", reconnected.id)
        assertEquals(next.id, model.state.value.playback?.id)
        model.stopPlayback()
    }

    /** The site as the Swift ExperienceProtocol served it, per configured state. */
    private class FakeSite {
        @Volatile var score = 1
        @Volatile var time = System.currentTimeMillis() / 1000.0 - 5
        @Volatile var failEvents = false
        @Volatile var failSchedule = false
        val requests = ConcurrentHashMap<String, Int>()

        val client: OkHttpClient = fixtureClient { request ->
            val path = request.url.encodedPath
            requests.merge(path, 1, Int::plus)
            when (path) {
                "/" -> FixtureReply(
                    """<script src="/index.js"></script><script src="https://site.example/tmp/njs.js"></script>""",
                    status = if (failSchedule) 503 else 200,
                )
                "/index.js" -> FixtureReply(
                    """
                    document.write('<ul class="item play" data-lid="1,1,1">');
                    document.write('<li class="lab_events"><span class="name">League</span></li>');
                    document.write('<li class="lab_time">09-06 12:00</li>');
                    document.write('<li class="lab_team_home"><strong class="name">Home</strong><img src="https://fixture.example/home.png"></li>');
                    document.write('<li class="lab_team_away"><strong class="name">Away</strong><img src="https://fixture.example/away.png"></li>');
                    document.write('<a class="item ok" href="https://experience.example/0.m3u8"><strong>Line 0</strong></a>');
                    document.write('</ul>');
                    """.trimIndent()
                )
                "/tmp/njs.js" -> FixtureReply("""{"base_zqlq_url":"/tmp/event?type=zqlq"}""")
                "/tmp/event" -> FixtureReply(
                    """{"success":true,"time":$time,"list":{"fields":["id","sportid","status","st_first","st_second","s1","s2","hs1","hs2","corner1","corner2"],""" +
                        """"values":[[1,1,3,${((time - 3600) * 1000).toLong()},${((time - 600) * 1000).toLong()},$score,0,1,0,6,3]]}}""",
                    status = if (failEvents) 503 else 200,
                )
                else -> FixtureReply("#EXTM3U\n#EXTINF:5,\nsegment.ts\n")
            }
        }
    }

    @Test
    fun scoreRefreshIsIndependentAndPreservesDataOnFailureAndOlderResponses() = runBlocking {
        val site = FakeSite()
        val model = MatchListModel(Preferences(MemoryPreferences()), scope, JrsClient("https://site.example/", site.client))
        model.refreshNow()
        assertEquals("1 - 0", model.state.value.matches.first().scoreText)
        val scheduleTime = model.state.value.lastUpdated
        val scoreTime = model.state.value.scoresUpdatedAt
        val homeRequests = site.requests["/"]

        site.failEvents = true
        model.refreshScores()
        assertEquals("1 - 0", model.state.value.matches.first().scoreText)
        assertEquals(scoreTime, model.state.value.scoresUpdatedAt)
        assertNotNull(model.state.value.scoreNotice)
        assertEquals(homeRequests, site.requests["/"])

        site.failEvents = false
        site.score = 2
        site.time += 1
        model.refreshScores()
        assertEquals("2 - 0", model.state.value.matches.first().scoreText)
        assertEquals(scheduleTime, model.state.value.lastUpdated)
        assertNull(model.state.value.scoreNotice)

        // An older snapshot never overwrites a newer one.
        site.score = 9
        site.time -= 1
        model.refreshScores()
        assertEquals("2 - 0", model.state.value.matches.first().scoreText)

        site.score = 2
        site.time += 1
        site.failEvents = true
        model.refreshNow()
        assertEquals("2 - 0", model.state.value.matches.first().scoreText)

        site.failEvents = false
        site.failSchedule = true
        site.score = 3
        site.time += 1
        model.refreshNow()
        assertNotNull(model.state.value.errorMessage)
        assertEquals("3 - 0", model.state.value.matches.first().scoreText)
    }

    @Test
    fun statisticsAndContinueUseLatestEventSnapshot() = runBlocking {
        val site = FakeSite().apply { score = 2; time = System.currentTimeMillis() / 1000.0 }
        val prefs = Preferences(MemoryPreferences())
        val listed = match("1,1,1")
        prefs.recordPlaybackSuccess(listed, source(0), 0, 1.0)
        val model = MatchListModel(prefs, scope, JrsClient("https://site.example/", site.client))
        assertNull(model.continueMatch())
        model.refreshNow()
        assertEquals("2 - 0", model.continueMatch()?.scoreText)
        val state = model.state.value.matches.first().providerState!!
        assertEquals("1 - 0", state.halftimeText)
        assertEquals("6 - 3", state.cornersText)
        model.setFilter(SportFilter.Recent)
        assertEquals("2 - 0", model.filteredMatches().first().scoreText)
        assertEquals("最近观看", model.sections().first().title)
        assertTrue(SportFilter.Recent in model.availableFilters())

        val now = System.currentTimeMillis()
        val firstHalf = ProviderMatchState(1, 1, now, now, homeHalfScore = 1, awayHalfScore = 0, homeCorners = -1, awayCorners = 0)
        assertNull(firstHalf.halftimeText)
        assertNull(firstHalf.cornersText)
        val basketball = ProviderMatchState(2, 5, now, now, homeScore = 54, awayScore = 58, homeHalfScore = 0, awayHalfScore = 0)
        assertNull(basketball.halftimeText)
        assertEquals(4 to 112, basketball.basketballSummary)
        assertNotEquals(null, basketball.scoreText)
    }
}

/** In-memory SharedPreferences for JVM tests (android.jar only has stubs). */
class MemoryPreferences : SharedPreferences {
    private val values = ConcurrentHashMap<String, Any>()

    override fun getAll(): Map<String, *> = HashMap(values)
    override fun getString(key: String, defValue: String?) = values[key] as? String ?: defValue
    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String, defValues: Set<String>?) = (values[key] as? Set<String>)?.toSet() ?: defValues
    override fun getInt(key: String, defValue: Int) = values[key] as? Int ?: defValue
    override fun getLong(key: String, defValue: Long) = values[key] as? Long ?: defValue
    override fun getFloat(key: String, defValue: Float) = values[key] as? Float ?: defValue
    override fun getBoolean(key: String, defValue: Boolean) = values[key] as? Boolean ?: defValue
    override fun contains(key: String) = values.containsKey(key)
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        private val changes = mutableMapOf<String, Any?>()
        private var clear = false
        override fun putString(key: String, value: String?) = apply { changes[key] = value }
        override fun putStringSet(key: String, values: Set<String>?) = apply { changes[key] = values?.toSet() }
        override fun putInt(key: String, value: Int) = apply { changes[key] = value }
        override fun putLong(key: String, value: Long) = apply { changes[key] = value }
        override fun putFloat(key: String, value: Float) = apply { changes[key] = value }
        override fun putBoolean(key: String, value: Boolean) = apply { changes[key] = value }
        override fun remove(key: String) = apply { changes[key] = null }
        override fun clear() = apply { clear = true }
        override fun commit(): Boolean {
            if (clear) values.clear()
            for ((key, value) in changes) if (value == null) values.remove(key) else values[key] = value
            return true
        }
        override fun apply() {
            commit()
        }
    }
}
