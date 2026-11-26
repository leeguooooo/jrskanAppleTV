package com.leeguoo.jrkan

import com.leeguoo.jrkan.data.AppConfig
import com.leeguoo.jrkan.data.ReplayParsing
import com.leeguoo.jrkan.data.ReplayRules
import com.leeguoo.jrkan.data.ReplayVideo
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.LocalDateTime
import java.time.ZoneId

/** Port of App/Tests/ReplayTests.swift against contracts/weibo-replay.json. */
class ReplayTest {
    private val rules = ReplayRules()

    private val fixture: JsonObject by lazy {
        val dir = System.getProperty("jrkan.contracts") ?: "../../contracts"
        Json.parseToJsonElement(File(dir, "weibo-replay.json").readText()) as JsonObject
    }

    private fun beijing(text: String): Long =
        LocalDateTime.parse(text.replace(' ', 'T')).atZone(ZoneId.of("Asia/Shanghai")).toInstant().toEpochMilli()

    private fun section(name: String) = fixture[name] as JsonObject

    @Test
    fun uploaderFeedKeepsOnlyRecordings() {
        val feed = ReplayParsing.waterfall(section("waterfall"), rules)
        assertEquals("5369096449295542", feed.nextCursor)
        assertEquals(11, feed.videos.size)
        val full = feed.videos.first { it.id == "Rt8axdsAW" }
        assertEquals(ReplayVideo.Matchup("热火", "76人"), full.matchup)
        assertEquals(ReplayVideo.Part.Full, full.part)
        assertEquals(beijing("2026-11-26 00:00"), full.titledDay)
        assertEquals("花查章", full.author)
        assertTrue(full.coverUrl!!.startsWith("https://"))
        assertEquals(ReplayVideo.Part.SecondHalf, feed.videos.first { it.id == "Rt8ybrfxz" }.part)
        assertEquals(ReplayVideo.Part.FirstHalf, feed.videos.first { it.id == "Rt7vGnFxj" }.part)
        val football = feed.videos.first { it.id == "Rt3yvoUza" }
        assertEquals(ReplayVideo.Matchup("巴塞罗那", "比利亚雷亚尔"), football.matchup)
        assertEquals(beijing("2026-11-22 00:00"), football.gameDay)
    }

    @Test
    fun searchMatchesBothWaysAndOrdersWholeGameFirst() {
        val found = ReplayParsing.search(section("search"), rules)
        assertFalse(found.isEmpty())
        assertTrue(found.none { "<" in it.text })
        val matched = ReplayParsing.videos("76人", "热火", beijing("2026-11-26 08:00"), found, rules)
        assertEquals(ReplayVideo.Part.Full, matched.first().part)
        assertEquals(matched.map { it.part.order }.sorted(), matched.map { it.part.order })
        assertTrue(matched.any { it.part == ReplayVideo.Part.Period(4) })
        assertTrue(ReplayParsing.videos("76人", "热火", beijing("2026-12-20 08:00"), found, rules).isEmpty())
        assertTrue(ReplayParsing.videos("湖人", "热火", beijing("2026-11-26 08:00"), found, rules).isEmpty())
    }

    @Test
    fun oldSeasonUploadIsRejected() {
        val old = ReplayParsing.video("old", "x", "1", beijing("2024-04-18 12:00"), "热火vs76人中文解说全场超清回放", 7000.0, null, rules)!!
        assertEquals(ReplayVideo.Part.Full, old.part)
        assertTrue(ReplayParsing.videos("76人", "热火", beijing("2026-11-26 08:00"), listOf(old), rules).isEmpty())
        val undated = ReplayParsing.video("new", "篮球之声", "2358578625", beijing("2026-11-26 09:37"), "热火vs76人 http://t.cn/AXTRyK8T", 11170.0, null, rules)!!
        assertEquals(ReplayVideo.Part.Full, undated.part)
        assertEquals(1, ReplayParsing.videos("76人", "热火", beijing("2026-11-26 08:00"), listOf(undated), rules).size)
    }

    @Test
    fun matchupAndPartParsing() {
        val cases = listOf(
            Triple("nba杯东部小组赛：热火vs76人 第二节回放！", "热火", "76人"),
            Triple("11月25日2026-2027赛季NBA杯 独行侠vs掘金全场高清回放", "独行侠", "掘金"),
            Triple("赛季NBA杯热火vs76人全场回放", "热火", "76人"),
            Triple("#热火vs76人# 下半场录像", "热火", "76人"),
            Triple("湖人 VS 爵士 中文解说全场", "湖人", "爵士"),
        )
        for ((text, left, right) in cases) assertEquals(text, ReplayVideo.Matchup(left, right), ReplayParsing.matchup(text))
        assertNull(ReplayParsing.matchup("盘点NBA最疯狂的压哨绝杀名场面！"))
        assertEquals(ReplayVideo.Part.Period(3), ReplayParsing.part("热火vs76人 第3节回放", 1700.0, rules))
        assertEquals(ReplayVideo.Part.Period(4), ReplayParsing.part("热火vs76人 第四节回放", 1700.0, rules))
        assertEquals(ReplayVideo.Part.SecondHalf, ReplayParsing.part("热火vs76人下半场录像回放", 4044.0, rules))
        assertEquals(ReplayVideo.Part.Other, ReplayParsing.part("热火vs76人", 2000.0, rules))
        assertNull(ReplayParsing.video("hl", "", "", 0, "热火vs76人 回放", 58.0, null, rules))
        assertNull(ReplayParsing.video("top", "", "", 0, "热火vs76人 十佳球集锦回放", 900.0, null, rules))
    }

    @Test
    fun plainTextDropsVideoLinkLabel() {
        val html = "11月26日 热火vs76人 第1节回放 <a  href=\"https://m.weibo.cn/search?containerid=231522\">#热火vs76人#</a> " +
            "<a href='https://video.weibo.com/show?fid=1034:1'><span class=\"surl-text\">JamesLebron的微博视频</span></a> &amp; more"
        assertEquals("11月26日 热火vs76人 第1节回放 #热火vs76人# & more", ReplayParsing.plainText(html))
    }

    @Test
    fun streamsBestFirstHttpsOnly() {
        val streams = ReplayParsing.streams(section("show"))
        assertEquals(listOf(1080, 720, 480), streams.map { it.height })
        assertTrue(streams.all { it.url.startsWith("https://") })
        assertNotNull(streams.first().expiresAt)
    }

    @Test
    fun groupsMergeUploadsOfOneGame() {
        val videos = ReplayParsing.waterfall(section("waterfall"), rules).videos + ReplayParsing.search(section("search"), rules)
        val groups = ReplayParsing.groups(videos)
        assertEquals("热火 vs 76人", groups.first().title)
        assertEquals(ReplayVideo.Part.Full, groups.first().videos.first().part)
        assertEquals(groups.first().videos.size, groups.first().videos.map { it.id }.toSet().size)
        assertEquals(4, groups.first { it.title == "独行侠 vs 掘金" }.videos.size)
        assertEquals(groups.map { it.day }.sortedDescending(), groups.map { it.day })
    }

    @Test
    fun fixtureEventsNeedBothTeamsAndAFinishedGame() {
        val root = Json.parseToJsonElement(
            """{"events":[
              {"id":"1","competitions":[{"date":"2026-11-26T00:00Z","status":{"type":{"completed":true}},"competitors":[{"homeAway":"home","team":{"abbreviation":"PHI"}},{"homeAway":"away","team":{"abbreviation":"MIA"}}]}]},
              {"id":"2","competitions":[{"date":"2026-11-26T01:00Z","status":{"type":{"completed":false}},"competitors":[{"homeAway":"home","team":{"abbreviation":"PHI"}},{"homeAway":"away","team":{"abbreviation":"MIA"}}]}]},
              {"id":"3","competitions":[{"date":"2026-11-26T00:00Z","status":{"type":{"completed":true}},"competitors":[{"homeAway":"home","team":{"abbreviation":"LAL"}},{"homeAway":"away","team":{"abbreviation":"MIA"}}]}]}
            ]}""",
        ) as JsonObject
        val found = com.leeguoo.jrkan.data.ReplayFixture.events(root, setOf("76人", "热火"))
        assertEquals(listOf("1"), found.map { it.id })
        assertEquals("76人", found.first().home)
        assertEquals("热火", found.first().away)
    }

    @Test
    fun replayModelKeepsUploadOrderAndStaysOutOfRecentWatches() {
        val videos = ReplayParsing.groups(ReplayParsing.waterfall(section("waterfall"), rules).videos).first { it.title == "热火 vs 76人" }.videos
        val prefs = com.leeguoo.jrkan.state.Preferences(MemoryPreferences())
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Unconfined)
        val model = com.leeguoo.jrkan.state.MatchPlaybackModel.replay(videos, null, prefs, scope)
        assertTrue(model.isReplay)
        assertTrue(model.match.id.startsWith("replay:"))
        // "全场高清回放" must not jump the queue the way 高清 does for live channels.
        assertEquals(videos.map { it.id }, model.resolvedChannels.map { it.id })
        assertEquals(videos.indices.toList(), model.rankedIndices)
        assertFalse(model.automaticFallbackEnabled)
        model.confirmPlayback("x", 1.0)
        assertTrue("a replay is not a 最近观看", prefs.recentWatches.value.isEmpty())
    }

    @Test
    fun cacheRoundTripAndLifetimes() {
        val dir = kotlin.io.path.createTempDirectory("replay-cache").toFile()
        com.leeguoo.jrkan.data.ReplayCache.directory = dir
        try {
            val cache = com.leeguoo.jrkan.data.ReplayCache
            val videos = ReplayParsing.waterfall(section("waterfall"), rules).videos
            cache.write("library", videos, cache.videoList)
            assertEquals(videos, cache.read("library", cache.videoList)!!.value)
            val kickoff = beijing("2026-11-26 08:00")
            assertEquals(15 * 60_000L, cache.searchLifetime(kickoff, true, kickoff + 3 * 3_600_000L))
            assertEquals(2 * 3_600_000L, cache.searchLifetime(kickoff, true, kickoff + 20 * 3_600_000L))
            assertEquals(24 * 3_600_000L, cache.searchLifetime(kickoff, true, kickoff + 5 * 86_400_000L))
            assertEquals(10 * 60_000L, cache.searchLifetime(kickoff, false, kickoff + 5 * 86_400_000L))
            val streams = ReplayParsing.streams(section("show"))
            cache.storeStreams(streams, "x")
            val expires = streams.first().expiresAt!!
            assertNotNull(cache.usableStreams("x", expires - 3_600_000L))
            assertNull("less than 10 minutes left", cache.usableStreams("x", expires - 300_000L))
        } finally {
            com.leeguoo.jrkan.data.ReplayCache.directory = null
            dir.deleteRecursively()
        }
    }

    @Test
    fun remoteConfigReplayBlock() {
        assertEquals(AppConfig.Replay(), AppConfig.parse("{}")!!.replay)
        val config = AppConfig.parse("""{"replay":{"enabled":false,"uploaders":["abc"],"minDuration":1,"windowHours":1000,"searchSuffix":" 录像"}}""")!!
        assertFalse(config.replay.enabled)
        assertEquals(AppConfig.Replay().uploaders, config.replay.uploaders)
        assertEquals(60.0, config.replay.minDuration, 0.0)
        assertEquals(240.0, config.replay.windowHours, 0.0)
        assertEquals(" 录像", config.replay.searchSuffix)
    }
}
