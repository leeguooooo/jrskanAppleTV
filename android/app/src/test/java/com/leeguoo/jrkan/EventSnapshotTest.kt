package com.leeguoo.jrkan

import com.leeguoo.jrkan.data.EventSnapshot
import com.leeguoo.jrkan.data.JrsClient
import com.leeguoo.jrkan.data.JrsException
import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.MatchSchedule
import com.leeguoo.jrkan.data.MatchSource
import com.leeguoo.jrkan.data.MatchStatus
import com.leeguoo.jrkan.data.ProviderMatchState
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Port of EventSnapshotTests in App/Tests/MatchScheduleTests.swift, plus ExperienceTests' feed checks. */
class EventSnapshotTest {
    private val nowSeconds = 1_788_663_314L
    private val now = nowSeconds * 1000

    private fun payload(rows: String, timestamp: Double = nowSeconds.toDouble()): String =
        """jrkanEvents({"success":true,"time":$timestamp,"list":{"fields":["id","sportid","status","st_first","st_second"],"values":[$rows]}});"""

    private fun match(id: String) = LiveMatch(
        id = id, league = "Test", time = "09-06 07:30", homeTeam = "Home", awayTeam = "Away",
        homeLogoUrl = null, awayLogoUrl = null, isHot = false,
        sources = listOf(MatchSource(id = "one", name = "Channel", pageUrl = "https://fixture.example/play")),
    )

    private fun assertInvalid(block: () -> Unit) {
        try {
            block()
            fail("expected InvalidResponse")
        } catch (e: JrsException) {
            assertEquals(JrsException.Kind.InvalidResponse, e.kind)
            assertEquals("目标站点返回了无效响应。", e.message)
        }
    }

    @Test
    fun scoresRefreshWithTheEventSnapshotAndDoNotInventZeros() {
        fun snapshot(home: String, away: String, code: Int = 3): EventSnapshot = EventSnapshot.parse(
            """{"success":true,"time":$nowSeconds,"list":{"fields":["id","sportid","status","st_first","st_second","s1","s2"],"values":[[101,1,$code,1788658800000,1788662771000,$home,$away]]}}""",
            now,
        )
        val input = listOf(match("101,1,101"))
        val first = snapshot("0", "0").applying(input)
        assertEquals("0 - 0", first[0].scoreText)
        val updated = snapshot("1", "2").applying(first)
        assertEquals("1 - 2", updated[0].scoreText)
        assertEquals("1 - 2", snapshot("1", "2", code = 7).applying(input)[0].scoreText)
        assertNull(snapshot("0", "0", code = 0).applying(input)[0].scoreText)
        assertNull(snapshot("null", "2").applying(input)[0].scoreText)
        assertNull(snapshot("-1", "2").applying(input)[0].scoreText)
        // Swift's `as? Int` rejects a fractional score instead of truncating it.
        assertNull(snapshot("1.5", "2").applying(input)[0].scoreText)
        assertEquals("1 - 2", snapshot("1.0", "2").applying(input)[0].scoreText)
        assertNull(snapshot("\"1\"", "2").applying(input)[0].scoreText)
        val basketball = ProviderMatchState(sportId = 2, code = 7, periodStartedAt = now, updatedAt = now, homeScore = 112, awayScore = 105)
        assertEquals("112 - 105", basketball.scoreText)
    }

    @Test
    fun eventSnapshotMatchesCompositeIdsAndKeepsChannelChoices() {
        val response = payload("[101,1,3,1788658800000,1788662771000],[101,2,0,1788663600000,1788663600000]")
        val snapshot = EventSnapshot.parse(response, now)
        val input = listOf(match("101,1,101"), match("101,2,101"), match("102,1,102"), match("other"))
        val output = snapshot.applying(input)
        assertEquals(listOf("101,1,101", "101,2,101", "other"), output.map { it.id })
        assertEquals(3, output[0].providerState?.code)
        assertEquals(0, output[1].providerState?.code)
        assertEquals(input[0].sources, output[0].sources)
        assertEquals("09-06 11:00", output[1].time)
    }

    @Test
    fun rejectsStaleOrMalformedSnapshotInsteadOfClearingSchedule() {
        assertInvalid { EventSnapshot.parse(payload("", timestamp = nowSeconds - 601.0), now) }
        assertInvalid { EventSnapshot.parse(payload("[101,1]"), now) }
        assertInvalid { EventSnapshot.parse("jrkanEvents({\"success\":false})", now) }
        assertInvalid { EventSnapshot.parse("jrkanEvents([\"invalid\",\"UMY=\"])", now) }
        // Kotlin-only: a non-integer status or a future timestamp is rejected too.
        assertInvalid { EventSnapshot.parse(payload("[101,1,3.5,1788658800000,1788662771000]"), now) }
        assertInvalid { EventSnapshot.parse(payload("", timestamp = nowSeconds + 300.0), now) }
    }

    @Test
    fun discoversWebsiteConfigurationWithoutHardcodingItsHost() {
        val base = "https://site.example/"
        val html = """document.write("<script src='//data.example/tmp/njs.js?_t="+Math.random());"""
        assertEquals("https://data.example/tmp/njs.js", EventSnapshot.configUrl(html, base))
        val config = """{"config":{"base_zqlq_url":"//data.example/tmp/event?type=zqlq"}}"""
        assertEquals(
            "https://data.example/tmp/event?type=zqlq&callback=jrkanEvents",
            EventSnapshot.eventUrl(config, base),
        )
        val withCallback = """{"base_zqlq_url":"/tmp/event?callback=old&type=zqlq"}"""
        assertEquals(
            "https://site.example/tmp/event?type=zqlq&callback=jrkanEvents",
            EventSnapshot.eventUrl(withCallback, base),
        )
    }

    @Test
    fun decodesWebsiteEncryptedEnvelope() {
        val encrypted = "3N36qZhpphxYmdWBDeQb08YkwJCCunTowCuPexJi40p9eZeQ32NEFTUBghA5sSC4b2noY5MLY2WjkwUAvkRy6KLPB5+G9kKXmIC077s4DEi7jwJnkLKgDQzLC64ogCWZ2Fh25qmtgtzKgbriuGiI/RfJesyAipD00k9K14zZyCn4RsmL6+gcDnW2QCFTDbZQf0h5TdTgaJEM0gIam3iWeA=="
        val snapshot = EventSnapshot.parse("jrkanEvents([\"$encrypted\",\"UMY=\"])", now)
        assertEquals(3, snapshot.events["1,101"]?.state?.code)
        assertEquals(MatchStatus.Live("54′"), snapshot.events["1,101"]?.state?.status(now))
    }

    /** EventFixtureProtocol from the Swift tests. */
    private val eventFixtures = fixtureClient { request ->
        val url = request.url
        when (url.encodedPath) {
            "/" -> FixtureReply("<script src=\"/index.js\"></script><script src=\"https://${url.host}/tmp/njs.js\"></script>")
            "/index.js" -> FixtureReply(
                listOf(101, 102).joinToString("\n") { id ->
                    """
                    document.write('<ul class="item play" data-lid="$id,1,$id">');
                    document.write('<li class="lab_events"><span class="name">League</span></li>');
                    document.write('<li class="lab_time">09-06 07:30</li>');
                    document.write('<li class="lab_team_home"><strong class="name">Home</strong><img src="https://fixture.example/home.png"></li>');
                    document.write('<li class="lab_team_away"><strong class="name">Away</strong><img src="https://fixture.example/away.png"></li>');
                    document.write('<a class="item ok" href="https://fixture.example/play"><strong>Channel</strong></a>');
                    document.write('</ul>');
                    """.trimIndent()
                },
            )
            "/tmp/njs.js" -> FixtureReply("""{"config":{"base_zqlq_url":"/tmp/event?type=zqlq"}}""")
            "/tmp/event" -> {
                if (url.host == "unavailable.example") {
                    null
                } else {
                    val t = System.currentTimeMillis() / 1000.0
                    FixtureReply(
                        "jrkanEvents({\"success\":true,\"time\":$t,\"list\":{\"fields\":[\"id\",\"sportid\",\"status\",\"st_first\",\"st_second\"],\"values\":[[101,1,4,${(t - 10800) * 1000},${t * 1000}]]}})",
                    )
                }
            }
            else -> null
        }
    }

    @Test
    fun clientAppliesEventsAndFallsBackToScheduleOnEventFailure() = runTest {
        val live = JrsClient("https://valid.example/", eventFixtures).fetchMatches()
        assertEquals(listOf("101,1,101"), live.map { it.id })
        assertEquals(MatchStatus.Live("加时赛"), MatchSchedule.status(live[0]))
        val fallback = JrsClient("https://unavailable.example/", eventFixtures).fetchMatches()
        assertEquals(2, fallback.size)
        assertTrue(fallback.all { it.providerState == null && it.sources.isNotEmpty() })
    }

    @Test
    fun clientReportsHomepageAndListingFailures() = runTest {
        val failing = fixtureClient { request ->
            when (request.url.host) {
                "down.example" -> FixtureReply("Unavailable", status = 503)
                else -> FixtureReply("<html>no scripts</html>")
            }
        }
        try {
            JrsClient("https://down.example/", failing).fetchSchedule()
            fail("expected InvalidResponse")
        } catch (e: JrsException) {
            assertEquals(JrsException.Kind.InvalidResponse, e.kind)
        }
        try {
            JrsClient("https://empty.example/", failing).fetchSchedule()
            fail("expected MissingListingScript")
        } catch (e: JrsException) {
            assertEquals(JrsException.Kind.MissingListingScript, e.kind)
            assertEquals("没有在首页找到比赛列表数据。", e.message)
        }
    }

    /** ExperienceProtocol's feed: halftime and corner columns reach the match. */
    @Test
    fun clientCarriesStatisticsColumns() = runTest {
        val experience = fixtureClient { request ->
            val t = System.currentTimeMillis() / 1000.0 - 5
            when (request.url.encodedPath) {
                "/" -> FixtureReply("<script src=\"/index.js\"></script><script src=\"https://${request.url.host}/tmp/njs.js\"></script>")
                "/index.js" -> FixtureReply(
                    """
                    document.write('<ul class="item play" data-lid="1,1,1">');
                    document.write('<li class="lab_events"><span class="name">League</span></li>');
                    document.write('<li class="lab_time">09-06 12:00</li>');
                    document.write('<li class="lab_team_home"><strong class="name">Home</strong><img src="https://fixture.example/home.png"></li>');
                    document.write('<li class="lab_team_away"><strong class="name">Away</strong><img src="https://fixture.example/away.png"></li>');
                    document.write('<a class="item ok" href="https://experience.example/0.m3u8"><strong>Line 0</strong></a>');
                    document.write('</ul>');
                    """.trimIndent(),
                )
                "/tmp/njs.js" -> FixtureReply("""{"base_zqlq_url":"/tmp/event?type=zqlq"}""")
                "/tmp/event" -> FixtureReply(
                    """{"success":true,"time":$t,"list":{"fields":["id","sportid","status","st_first","st_second","s1","s2","hs1","hs2","corner1","corner2"],"values":[[1,1,3,${(t - 3600) * 1000},${(t - 600) * 1000},2,0,1,0,6,3]]}}""",
                )
                else -> null
            }
        }
        val match = JrsClient("https://experience.example/", experience).fetchMatches().single()
        assertEquals("2 - 0", match.scoreText)
        assertEquals("1 - 0", match.providerState?.halftimeText)
        assertEquals("6 - 3", match.providerState?.cornersText)
    }
}
