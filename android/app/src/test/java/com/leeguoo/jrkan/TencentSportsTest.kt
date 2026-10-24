package com.leeguoo.jrkan

import com.leeguoo.jrkan.data.*
import com.leeguoo.jrkan.state.DanmakuQueue
import com.leeguoo.jrkan.state.MatchInsightsModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.time.Instant

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class TencentSportsTest {
    private val mid = "100000:10022600102"
    private fun game() = LiveMatch("3931544,2,3931544", "NBA", "10-24 10:00", "湖人", "快船", null, null, false, emptyList())
    private fun channel(id: String = "10022600102", path: String = "kbs") = MatchSource(id, "中文高清 Q", "https://fixture.example/play/$path/?id=$id&id2=")
    private fun obj(text: String) = Json.parseToJsonElement(text).jsonObject
    private fun fixture() = Json.parseToJsonElement(File(System.getProperty("jrkan.contracts"), "tencent-sports.json").readText()).jsonObject

    @Test fun sharedAndroidAppleContract() {
        val data = fixture()
        for (entry in data.getValue("channels").jsonArray) {
            val row = entry.jsonObject
            val source = MatchSource("shared", row.getValue("name").jsonPrimitive.content, row.getValue("url").jsonPrimitive.content)
            assertEquals(row.getValue("priority").jsonPrimitive.int, source.playbackPriority)
            assertEquals(row["mid"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content, TencentSportsClient.candidateMid(game(), listOf(source)))
        }
        val snapshot = TencentSportsClient.parseStatistics(data.getValue("statistics").jsonObject, mid)
        assertEquals("0 : —", snapshot.score)
        assertEquals(4, snapshot.tables.size)
        assertEquals(listOf("篮板", "—", "1"), snapshot.comparisonTable!!.rows[1])
        assertEquals(listOf(listOf("77 球员甲", "1'00", "0")), snapshot.playerTables[0].rows)
        val comments = TencentSportsClient.parseComments(data.getValue("comments").jsonObject, mid, data.getValue("nowMs").jsonPrimitive.long)
        assertEquals(listOf("keep"), comments.map { it.id })
        assertEquals("好球", comments.single().text)
    }

    @Test fun matchingRejectsConflictingIdsWrongTeamsTimeAndCompetition() {
        assertEquals(mid, TencentSportsClient.candidateMid(game(), listOf(channel())))
        assertEquals("100000:10022600101", TencentSportsClient.candidateMid(game(), listOf(channel("10022600101", "txf"))))
        assertNull(TencentSportsClient.candidateMid(game(), listOf(channel(), channel("10022600103"))))
        assertNull(TencentSportsClient.candidateMid(game().copy(league = "英超"), listOf(channel())))
        val now = Instant.parse("2026-10-24T02:00:00Z").toEpochMilli()
        val info = obj("""{"mid":"$mid","leftName":"快船","rightName":"湖人","startTime":"2026-10-24 10:00:00"}""")
        assertTrue(TencentSportsClient.matches(info, game(), mid, now))
        assertFalse(TencentSportsClient.matches(JsonObject(info + ("rightName" to JsonPrimitive("勇士"))), game(), mid, now))
        assertFalse(TencentSportsClient.matches(JsonObject(info + ("startTime" to JsonPrimitive("2026-10-25 10:00:00"))), game(), mid, now))
        assertFalse(TencentSportsClient.matches(info, game(), "wrong", now))
    }

    @Test fun comparisonBarsAndUnicodeStayValid() {
        assertEquals(0.6f, SportsStatComparison.from(listOf("得分", "60", "40"))!!.leftShare)
        assertEquals(0.4f, SportsStatComparison.from(listOf("命中率", "40% (4/10)", "60% (6/10)"))!!.leftShare)
        assertEquals(0.5f, SportsStatComparison.from(listOf("得分", "0", "0"))!!.leftShare)
        assertNull(SportsStatComparison.from(listOf("得分", "—", "0")))
        assertNull(SportsStatComparison.from(listOf("得分", "NaN", "0")))
        val message = "🏀".repeat(100)
        val comments = TencentSportsClient.parseComments(obj("""{"list":[{"commentId":"emoji","mid":"$mid","type":"0","postTime":"990","content":"$message"}]}"""), mid, 1_000_000)
        assertEquals(80, comments.single().text.codePointCount(0, comments.single().text.length))
    }

    @Test fun clientBypassesCacheRequiresSuccessfulProviderAndMatch() = runTest {
        val now = Instant.parse("2026-10-24T02:00:00Z").toEpochMilli()
        val client = TencentSportsClient(fixtureClient { request ->
            assertNotNull(request.url.queryParameter("_t"))
            assertEquals("https://sports.qq.com/", request.header("Referer"))
            assertNull(request.header("Cookie")); assertNull(request.header("Authorization"))
            when (request.url.encodedPath) {
                "/kbs/matchDetail" -> FixtureReply("""{"code":0,"data":{"matchInfo":{"mid":"$mid","leftName":"快船","rightName":"湖人","startTime":"2026-10-24 10:00:00"}}}""")
                "/dmComment/liveList" -> FixtureReply("""{"code":55,"data":{}}""")
                else -> FixtureReply("not JSON")
            }
        }) { now }
        client.verify(game(), mid)
        try { client.comments(mid); fail("Provider errors must not become empty success") } catch (_: IOException) {}
        try { client.statistics(mid, game()); fail("Invalid JSON must fail") } catch (_: IOException) {}
    }

    private inner class Provider : SportsDataProvider {
        var verifies = 0; var stats = 0; var polls = 0
        var failStats = false; var failComments = false
        override suspend fun verify(match: LiveMatch, mid: String) { verifies++ }
        override suspend fun statistics(mid: String, match: LiveMatch): SportsSnapshot {
            stats++
            if (failStats) throw IOException("offline")
            return TencentSportsClient.parseStatistics(fixture().getValue("statistics").jsonObject, mid, 1_000_000)
        }
        override suspend fun comments(mid: String): List<SportsComment> {
            polls++
            if (failComments) throw IOException("comments offline")
            return listOf(SportsComment("one", "好球", 990_000))
        }
    }

    @Test fun pollingCancelsAndHandoffDoesNotReverifyOrDuplicate() = runTest {
        val provider = Provider(); val model = MatchInsightsModel(provider) { 1_000_000 }
        var watch = backgroundScope.launch { model.watch(game(), listOf(channel())) }
        runCurrent()
        assertEquals(mid, model.state.value.mid); assertEquals(1, provider.stats)
        val comments = backgroundScope.launch { model.watchComments() }
        runCurrent(); assertEquals(1, model.state.value.comments.size)
        advanceTimeBy(10_001); runCurrent()
        assertEquals(1, model.state.value.comments.size)
        watch.cancelAndJoin()
        watch = backgroundScope.launch { model.watch(game(), listOf(channel())) }; runCurrent()
        assertEquals(1, provider.verifies)
        val calls = provider.stats
        watch.cancelAndJoin(); comments.cancelAndJoin()
        advanceTimeBy(90_000); runCurrent()
        assertEquals(calls, provider.stats)
        val polls = provider.polls
        model.setDanmakuEnabled(false)
        val disabled = backgroundScope.launch { model.watchComments() }; runCurrent(); disabled.cancelAndJoin()
        assertTrue(model.state.value.comments.isEmpty()); assertEquals(polls, provider.polls)
    }

    @Test fun outagesKeepLastStatisticsAndNeverThrowToCaller() = runTest {
        val provider = Provider(); val model = MatchInsightsModel(provider) { 1_000_000 }
        val watch = backgroundScope.launch { model.watch(game(), listOf(channel())) }; runCurrent()
        val first = model.state.value.snapshot
        provider.failStats = true; provider.failComments = true
        val comments = backgroundScope.launch { model.watchComments() }; runCurrent()
        advanceTimeBy(30_001); runCurrent()
        assertEquals(first, model.state.value.snapshot)
        assertTrue(model.state.value.status.contains("上次结果"))
        assertTrue(model.state.value.comments.isEmpty())
        watch.cancelAndJoin(); comments.cancelAndJoin()
    }

    @Test fun queueIsBoundedDeduplicatedAndExpiresWithoutNetwork() {
        var now = 1_000_000L
        val queue = DanmakuQueue { now }
        val comments = (0..49).map { SportsComment("$it", "消息 $it", now) }
        queue.offer(comments); queue.offer(comments)
        assertEquals(20, queue.size)
        assertEquals("30", queue.next()!!.id)
        queue.clearPending(); queue.offer(comments)
        assertEquals(0, queue.size)
        queue.offer(listOf(SportsComment("later", "稍后", now)))
        now += 120_001; assertNull(queue.next())
    }

    @Test fun livePublicReadOnlyTencentContract() = runTest {
        assumeTrue(System.getProperty("jrkan.live") == "1")
        val client = TencentSportsClient()
        val reference = client.referenceMatch(mid)
        client.verify(reference, mid)
        val stats = client.statistics(mid, reference)
        assertTrue(stats.tables.isNotEmpty())
        client.comments(mid)
    }
}
