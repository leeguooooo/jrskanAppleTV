package com.leeguoo.jrkan

import com.leeguoo.jrkan.data.*
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.Assume.assumeTrue
import kotlinx.coroutines.CancellationException
import java.io.File
import java.io.IOException

class MultiSportsTest {
    private val fixture get() = Json.parseToJsonElement(File(System.getProperty("jrkan.contracts"), "multi-sports.json").readText()).jsonObject
    private val now get() = fixture.getValue("nowMs").jsonPrimitive.long
    private fun game(home: String = "湖人", away: String = "快船", time: String = "10-24 10:00") = LiveMatch("test", "NBA", time, home, away, null, null, false, emptyList())
    private val channels = listOf(MatchSource("t", "中文高清Q", "https://fixture.example/play/kbs/?id=10022600102"))
    private fun migu() = MultiSportsClient.miguStatistics(fixture.getValue("migu").jsonObject, "120000588273", game(), now)

    @Test fun cbaClubNamesMatchShanghaiFujianWithoutMergingDistinctClubs() = runTest {
        val f = fixture; val row = f.getValue("shanghai").jsonObject
        for ((name, expected) in f.getValue("cbaAliases").jsonObject) assertEquals(expected.jsonPrimitive.content, MultiSportsClient.canonical(name))
        assertEquals("上海申花", MultiSportsClient.canonical("上海申花"))
        assertNotEquals(MultiSportsClient.canonical("北京首钢"), MultiSportsClient.canonical("北京控股"))
        assertNotEquals(MultiSportsClient.canonical("浙江稠州金租"), MultiSportsClient.canonical("浙江浙商证券"))
        val match = game("上海", "福建", "10-24 19:35").copy(league = "CBA")
        val clock = row.getValue("nowMs").jsonPrimitive.long
        val stats = MultiSportsClient.miguStatistics(row.getValue("statistics").jsonObject, "120000594063", match, clock)
        assertEquals(2, stats.playerTables.size)
        assertTrue(MultiSportsClient.matches(listOf("上海久事", "福建晋江文旅"), "202610241915", "yyyyMMddHHmm", match, clock))
        assertFalse(MultiSportsClient.matches(listOf("上海久事", "北京控股"), "202610241915", "yyyyMMddHHmm", match, clock))
        assertFalse(MultiSportsClient.matches(listOf("上海久事", "福建晋江文旅"), "202610251915", "yyyyMMddHHmm", match, clock))
        val mid = "100008:10011111111"
        val info = buildJsonObject { put("mid", mid); put("leftName", "上海久事"); put("rightName", "福建晋江文旅"); put("startTime", "2026-10-24 19:35:00") }
        assertTrue(TencentSportsClient.matches(info, match, mid, clock))
        assertFalse(TencentSportsClient.matches(info, match, "wrong", clock))
        val provider = MultiSportsClient(client = fixtureClient { request ->
            when {
                request.url.encodedPath == "/p/home/494d21a4d6ee453b8b86bd3bb7658ed6" -> FixtureReply("<script>window.__INITIAL_GROUPS_STATE__ = {\"rows\":[${row.getValue("catalog")}]};</script>")
                request.url.encodedPath.endsWith("/120000594063") -> FixtureReply(row.getValue("statistics").toString())
                else -> null
            }
        }, clock = { clock })
        val key = provider.prepare(match, emptyList())!!
        assertEquals("咪咕视频", provider.statistics(key, match).sourceName)
    }

    @Test fun liveShanghaiFujianCanMatchWithoutTencentEventID() = runTest {
        assumeTrue(System.getProperty("jrkan.live") == "1")
        val match = game("上海", "福建", "10-24 19:35").copy(league = "CBA")
        val provider = MultiSportsClient()
        val key = provider.prepare(match, emptyList())!!
        val stats = provider.statistics(key, match)
        assertEquals("migu:120000594063", stats.mid)
        assertEquals(2, stats.playerTables.size)
        val comments = provider.comments(key)
        assertTrue(comments.all { it.id.startsWith("migu:") })
    }

    @Test fun sharedMiguEspnCatalogAndCommentContract() {
        val data = fixture
        val m = migu()
        assertEquals("咪咕视频", m.sourceName); assertEquals("125 : 117", m.score)
        assertEquals(2, m.playerTables.size); assertTrue(m.comparisonTable!!.rows.any { it[0] == "真实命中率" })
        assertEquals(listOf("migu:keep"), MultiSportsClient.miguComments(data.getValue("comments").jsonObject, "120000588273", now).map { it.id })
        val html = "<script>window.__INITIAL_GROUPS_STATE__ = {\"nested\":[${data.getValue("catalog")}]};window.__INITIAL_COMPS_STATE__ = {};</script>"
        assertEquals("120000588273", MultiSportsClient.catalogRows(html).single()["pID"]!!.jsonPrimitive.content)
        val e = MultiSportsClient.espnStatistics(data.getValue("espn").jsonObject, data.getValue("espnID").jsonPrimitive.content, game("雄鹿", "公牛", "10-24 04:00"), now)
        assertEquals("ESPN", e.sourceName); assertEquals(2, e.playerTables.size)
        assertEquals("得分", e.playerTables.first().headers[2])
        assertFalse(MultiSportsClient.matches(listOf("湖人", "勇士"), "202610240945", "yyyyMMddHHmm", game(), now))
        assertFalse(MultiSportsClient.matches(listOf("湖人", "快船"), "202610250945", "yyyyMMddHHmm", game(), now))
        try { MultiSportsClient.miguStatistics(data.getValue("migu").jsonObject, "120000588273", game("勇士"), now); fail("Must reject wrong match") } catch (_: IOException) {}
        try { MultiSportsClient.espnStatistics(data.getValue("espn").jsonObject, "wrong", game("雄鹿", "公牛", "10-24 04:00"), now); fail("Must reject wrong id") } catch (_: IOException) {}
    }

    @Test fun wholeTablesPreferTencentFillOnlyMissingAndPreserveHomeAwayAndZero() {
        val m = migu()
        val primary = m.copy(sourceName = "腾讯体育", score = "0 : —", tables = listOf(SportsTable("球队技术统计", listOf("项目", "湖人", "快船"), listOf(listOf("得分", "0", "—")))))
        val selected = MultiSportsClient.select(listOf(primary, m))!!
        assertEquals("0 : —", selected.score)
        assertEquals("腾讯体育", selected.comparisonTable!!.sourceName)
        assertEquals("0", selected.comparisonTable!!.rows[0][1])
        assertEquals("咪咕视频", selected.playerTables.first().sourceName)
        assertTrue(MultiSportsClient.complete(selected))
        val reversed = primary.copy(left = "快船", right = "湖人", tables = emptyList())
        val reoriented = MultiSportsClient.select(listOf(reversed, m))!!
        assertEquals("快船", reoriented.comparisonTable!!.headers[1])
        assertEquals(m.comparisonTable!!.rows.first()[2], reoriented.comparisonTable!!.rows.first()[1])
        assertEquals("快船", reoriented.periodTable!!.rows.first()[0])
    }

    @Test fun fallbackWithoutTencentIDAndRecoveryRechecksPreferredSource() = runTest {
        val m = migu(); var available = false; var fetches = 0
        val provider = object : SportsDataProvider {
            override suspend fun verify(match: LiveMatch, mid: String) {}
            override suspend fun statistics(mid: String, match: LiveMatch): SportsSnapshot { if (!available) throw IOException("offline"); return m.copy(sourceName = "腾讯体育") }
            override suspend fun comments(mid: String): List<SportsComment> = if (available) listOf(SportsComment("preferred", "腾讯消息", now - 1000)) else emptyList()
        }
        val http = fixtureClient { request ->
            assertNull(request.header("Cookie")); assertNull(request.header("Authorization")); fetches++
            when {
                request.url.encodedPath.startsWith("/p/home/") -> FixtureReply("<script>window.__INITIAL_GROUPS_STATE__ = {\"matches\":[${fixture.getValue("catalog")}]};</script>")
                request.url.encodedPath.contains("/live/statistics/") -> FixtureReply(fixture.getValue("migu").toString())
                request.url.encodedPath.contains("/comment/") -> FixtureReply(fixture.getValue("comments").toString())
                else -> null
            }
        }
        val client = MultiSportsClient(provider, http) { now }
        val key = client.prepare(game(), channels)!!
        assertEquals("咪咕视频", client.statistics(key, game()).sourceName)
        assertEquals("migu:keep", client.comments(key).single().id)
        available = true; val previous = fetches
        assertEquals("腾讯体育", client.statistics(key, game()).sourceName)
        assertEquals("tencent:preferred", client.comments(key).single().id)
        assertEquals(previous, fetches)
        assertEquals("migu:keep", client.comments(key, setOf("tencent:preferred")).single().id)
        assertTrue(client.comments(key, setOf("tencent:preferred", "migu:keep")).isEmpty())
        val noTencent = client.prepare(game(), emptyList())!!
        assertEquals("咪咕视频", client.statistics(noTencent, game()).sourceName)
    }

    @Test fun espnIsUsedWhenBothChineseSourcesFail() = runTest {
        val f = fixture; val match = game("雄鹿", "公牛", "10-24 04:00")
        val client = MultiSportsClient(client = fixtureClient { request ->
            when (request.url.encodedPath.substringAfterLast('/')) {
                "scoreboard" -> FixtureReply(buildJsonObject { put("events", buildJsonArray { add(buildJsonObject { put("id", f.getValue("espnID")); put("competitions", f.getValue("espn").jsonObject.getValue("header").jsonObject.getValue("competitions")) }) }) }.toString())
                "summary" -> FixtureReply(f.getValue("espn").toString())
                else -> null
            }
        }, clock = { now })
        val key = client.prepare(match, emptyList())!!
        assertEquals("ESPN", client.statistics(key, match).sourceName)
    }
    @Test fun cancellationDoesNotStartFallbackTraffic() = runTest {
        var fallback = 0
        val provider = object : SportsDataProvider {
            override suspend fun verify(match: LiveMatch, mid: String) {}
            override suspend fun statistics(mid: String, match: LiveMatch): SportsSnapshot = throw CancellationException("left screen")
            override suspend fun comments(mid: String): List<SportsComment> = throw CancellationException("left screen")
        }
        val client = MultiSportsClient(provider, fixtureClient { fallback++; null }) { now }
        val key = client.prepare(game(), channels)!!
        try { client.statistics(key, game()); fail("Must propagate cancellation") } catch (_: CancellationException) {}
        try { client.comments(key); fail("Must propagate cancellation") } catch (_: CancellationException) {}
        assertEquals(0, fallback)
    }

    @Test fun liveAnonymousMiguAndEspnContracts() = runTest {
        assumeTrue(System.getProperty("jrkan.live") == "1")
        val client = MultiSportsClient()
        val key = client.prepare(game(), emptyList())!!
        val result = client.statistics(key, game())
        assertEquals("咪咕视频", result.sourceName)
        assertTrue(MultiSportsClient.complete(result))
        client.comments(key)
        val page = Http.get("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=401909848", timeoutSeconds = 12)
        assertEquals(200, page.status)
        val espn = MultiSportsClient.espnStatistics(Json.parseToJsonElement(page.utf8()!!).jsonObject, "401909848", game("雄鹿", "公牛", "10-24 04:00"), now)
        assertEquals(2, espn.playerTables.size)
    }

}
