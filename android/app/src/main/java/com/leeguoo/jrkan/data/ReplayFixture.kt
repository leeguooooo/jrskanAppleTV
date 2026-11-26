package com.leeguoo.jrkan.data

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * The real fixture behind a set of replays, for 数据 (ReplayStats.swift). NBA
 * only: exactly one finished ESPN game with both teams, on that Beijing day and
 * before the first upload; anything less certain gives no statistics.
 */
object ReplayFixture {
    data class Event(val id: String, val start: Long, val home: String, val away: String)

    @kotlinx.serialization.Serializable
    private class Cached(val match: LiveMatch? = null)

    /** Cached: found for 30 days, not found for 6 hours (never after a network failure). */
    suspend fun nbaMatch(videos: List<ReplayVideo>, now: Long = System.currentTimeMillis()): LiveMatch? {
        val first = videos.firstOrNull() ?: return null
        val matchup = first.matchup ?: return null
        val teams = setOf(MultiSportsClient.canonical(matchup.left), MultiSportsClient.canonical(matchup.right))
        if (!nbaTeams.containsAll(teams)) return null
        val key = "fixture:${matchup.key}@${first.gameDay}"
        ReplayCache.read(key, Cached.serializer())?.let { hit ->
            val lifetime = if (hit.value.match == null) 6 * 3_600_000L else 30 * 86_400_000L
            if (now - hit.savedAt < lifetime) return hit.value.match
        }
        val (match, complete) = lookUp(videos, teams)
        if (match != null || complete) ReplayCache.write(key, Cached(match), Cached.serializer())
        return match
    }

    private suspend fun lookUp(videos: List<ReplayVideo>, teams: Set<String>): Pair<LiveMatch?, Boolean> {
        val first = videos.first()
        val earliest = videos.minOf { it.postedAt }
        val day = first.gameDay
        val ny = DateTimeFormatter.ofPattern("yyyyMMdd").withZone(ZoneId.of("America/New_York"))
        val dates = listOf(day - 86_400_000L, day, day + 43_200_000L).map { ny.format(Instant.ofEpochMilli(it)) }.toSet()
        // In parallel and short: this sits between the tap and the picture.
        val pages = coroutineScope {
            dates.map { date ->
                async {
                    runCatching {
                        val page = Http.get("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=$date", timeoutSeconds = 4)
                        if (page.status != 200) null
                        else events(Json.parseToJsonElement(page.utf8OrLatin1()) as JsonObject, teams)
                    }.getOrNull()
                }
            }.awaitAll()
        }
        val complete = pages.all { it != null }
        val found = pages.filterNotNull().flatten()
        val candidates = found.distinctBy { it.id }.filter { ReplayParsing.beijingDay(it.start) == day && it.start < earliest }
        val game = candidates.singleOrNull() ?: return null to complete
        val clock = DateTimeFormatter.ofPattern("MM-dd HH:mm").withZone(ReplayParsing.beijing)
        return LiveMatch(
            id = "replay-fixture:espn:${game.id}", league = "NBA", time = clock.format(Instant.ofEpochMilli(game.start)),
            homeTeam = game.home, awayTeam = game.away, homeLogoUrl = null, awayLogoUrl = null, isHot = false, sources = emptyList(),
        ) to true
    }

    /** Finished games on one scoreboard page with exactly these two teams. */
    fun events(root: JsonObject, teams: Set<String>): List<Event> =
        (root["events"] as? JsonArray).orEmpty().mapNotNull { event ->
            val e = event as? JsonObject ?: return@mapNotNull null
            val comp = (e["competitions"] as? JsonArray)?.firstOrNull() as? JsonObject ?: return@mapNotNull null
            val competitors = (comp["competitors"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
            if (competitors.size != 2) return@mapNotNull null
            fun name(side: String) = competitors.firstOrNull { it["homeAway"].str() == side }
                ?.let { MultiSportsClient.canonical(((it["team"] as? JsonObject)?.get("abbreviation")).str().orEmpty()) }
            val home = name("home") ?: return@mapNotNull null
            val away = name("away") ?: return@mapNotNull null
            val completed = (((comp["status"] as? JsonObject)?.get("type") as? JsonObject)?.get("completed") as? JsonPrimitive)?.booleanOrNull
            if (setOf(home, away) != teams || completed != true) return@mapNotNull null
            val raw = comp["date"].str() ?: return@mapNotNull null
            val start = runCatching { Instant.parse(raw.replace("Z", ":00Z")) }.recoverCatching { Instant.parse(raw) }.getOrNull()
                ?: return@mapNotNull null
            Event(e["id"].str().orEmpty(), start.toEpochMilli(), home, away)
        }

    private fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.content?.takeIf { it.isNotEmpty() && it != "null" }

    val nbaTeams = setOf("勇士", "湖人", "快船", "灰熊", "尼克斯", "鹈鹕", "马刺", "爵士", "奇才", "太阳", "老鹰", "凯尔特人",
        "篮网", "黄蜂", "公牛", "骑士", "独行侠", "掘金", "活塞", "火箭", "步行者", "热火", "雄鹿", "森林狼", "雷霆", "魔术", "76人",
        "开拓者", "国王", "猛龙")
}

/** Where each recording was left off (ReplayResume in Replay.swift); 30 days. */
object ReplayResume {
    private const val LIFETIME = 30 * 86_400_000L
    private var prefs: SharedPreferences? = null

    fun init(context: Context) {
        prefs = context.getSharedPreferences("jrkan-replay-positions", Context.MODE_PRIVATE)
    }

    fun positionMs(id: String, now: Long = System.currentTimeMillis()): Long? {
        val raw = prefs?.getString(id, null) ?: return null
        val parts = raw.split(",").mapNotNull { it.toLongOrNull() }
        if (parts.size != 2 || now - parts[1] > LIFETIME) return null
        return parts[0]
    }

    /** Barely started or watched to the end forgets the spot. */
    fun save(positionMs: Long, durationMs: Long?, id: String, now: Long = System.currentTimeMillis()) {
        val prefs = prefs ?: return
        val editor = prefs.edit()
        prefs.all.forEach { (key, value) ->
            val stamp = (value as? String)?.substringAfter(",")?.toLongOrNull() ?: 0
            if (now - stamp > LIFETIME) editor.remove(key)
        }
        if (positionMs < 30_000 || (durationMs != null && durationMs > 0 && positionMs > durationMs - 60_000)) editor.remove(id)
        else editor.putString(id, "$positionMs,$now")
        editor.apply()
    }
}
