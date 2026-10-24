package com.leeguoo.jrkan.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.CookieJar
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import java.io.IOException
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/** Same contracts and bounds as App/Sources/Shared/TencentSports.swift. */
data class SportsComment(val id: String, val text: String, val postedAt: Long)
data class SportsTable(val title: String, val headers: List<String>, val rows: List<List<String>>, val sourceName: String = "")
data class SportsSnapshot(
    val mid: String, val left: String, val right: String, val score: String,
    val period: String, val tables: List<SportsTable>, val updatedAt: Long,
    val leftBadge: String? = null, val rightBadge: String? = null,
    val sourceName: String = "腾讯体育", val scoreSourceName: String? = null,
) {
    val periodTable: SportsTable? get() = tables.firstOrNull { it.title == "分节得分" }
    val comparisonTable: SportsTable? get() = tables.firstOrNull { it.title == "球队技术统计" }
    val playerTables: List<SportsTable> get() = tables.filter { it.title.endsWith("球员技术统计") }
}

interface SportsDataProvider {
    suspend fun prepare(match: LiveMatch, channels: List<MatchSource>): String? {
        val mid = TencentSportsClient.candidateMid(match, channels) ?: return null
        verify(match, mid)
        return mid
    }
    suspend fun verify(match: LiveMatch, mid: String)
    suspend fun statistics(mid: String, match: LiveMatch, onPartial: suspend (SportsSnapshot) -> Unit): SportsSnapshot {
        val value = statistics(mid, match); onPartial(value); return value
    }
    suspend fun statistics(mid: String, match: LiveMatch): SportsSnapshot
    suspend fun comments(mid: String): List<SportsComment>
}

/** Public GETs only, with isolated cookies/cache/timeouts and no account token. */
class TencentSportsClient(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .cookieJar(CookieJar.NO_COOKIES).cache(null)
        .connectTimeout(8, TimeUnit.SECONDS).readTimeout(8, TimeUnit.SECONDS)
        .callTimeout(12, TimeUnit.SECONDS).build(),
    private val clock: () -> Long = System::currentTimeMillis,
) : SportsDataProvider {
    /** Debug UI previews obtain match facts from the same public provider.
     * Normal app navigation still verifies against the JRS schedule. */
    suspend fun referenceMatch(mid: String): LiveMatch {
        if (!mid.matches(Regex("^10000[08]:[0-9]{10,12}$"))) throw invalid()
        val data = get("matchweb.sports.qq.com", "/kbs/matchDetail", mapOf("mid" to mid))
        val info = data["matchInfo"] as? JsonObject ?: throw invalid()
        if (text(info["mid"]) != mid) throw invalid()
        val time = try { LocalDateTime.parse(text(info["startTime"]), kickoffFormat).format(DateTimeFormatter.ofPattern("MM-dd HH:mm")) }
            catch (_: Exception) { throw invalid() }
        return LiveMatch("qa:$mid", if (mid.startsWith("100000:")) "NBA" else "CBA", time,
            text(info["leftName"]), text(info["rightName"]), text(info["leftBadge"]).ifEmpty { null },
            text(info["rightBadge"]).ifEmpty { null }, false,
            listOf(MatchSource("qa-reference", "中文高清 Q", "https://fixture.example/play/kbs/?id=${mid.substringAfter(':')}")))
    }

    override suspend fun verify(match: LiveMatch, mid: String) {
        val data = get("matchweb.sports.qq.com", "/kbs/matchDetail", mapOf("mid" to mid))
        if (!matches(data["matchInfo"] as? JsonObject ?: throw invalid(), match, mid, clock())) throw invalid()
    }

    override suspend fun statistics(mid: String, match: LiveMatch): SportsSnapshot {
        val data = get("matchweb.sports.qq.com", "/kbs/matchStat", mapOf("mid" to mid))
        val info = (data["teamInfo"] as? JsonObject)?.toMutableMap() ?: throw invalid()
        info["mid"] = JsonPrimitive(mid)
        if (!matches(JsonObject(info), match, mid, clock())) throw invalid()
        return parseStatistics(data, mid, clock())
    }

    override suspend fun comments(mid: String): List<SportsComment> {
        val data = get("app.sports.qq.com", "/dmComment/liveList", mapOf("mid" to mid, "topN" to "20", "commentId" to "0"))
        return parseComments(data, mid, clock())
    }

    private suspend fun get(host: String, path: String, query: Map<String, String>): JsonObject {
        val url = "https://$host$path".toHttpUrl().newBuilder()
        (query + ("_t" to clock().toString())).toSortedMap().forEach { (key, value) -> url.addQueryParameter(key, value) }
        val page = Http.get(url.build().toString(), referer = "https://sports.qq.com/", timeoutSeconds = 12, client = client)
        currentCoroutineContext().ensureActive()
        if (page.status != 200 || page.body.size > 2_000_000) throw invalid()
        return withContext(Dispatchers.Default) {
            val root = try { Json.parseToJsonElement(page.utf8() ?: throw invalid()) as? JsonObject }
                catch (_: IllegalArgumentException) { null } ?: throw invalid()
            if (text(root["code"]) != "0") throw invalid()
            root["data"] as? JsonObject ?: throw invalid()
        }
    }

    companion object {
        private val kickoffFormat = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss", Locale.US)
        private val shanghai = ZoneId.of("Asia/Shanghai")
        private fun invalid() = IOException("腾讯体育数据暂不可用。")
        private fun text(value: JsonElement?, missing: String = ""): String =
            (value as? JsonPrimitive)?.takeUnless { it.toString() == "null" }?.content?.takeIf { it.isNotEmpty() } ?: missing
        private fun strings(value: JsonElement?): List<String>? =
            (value as? JsonArray)?.takeIf { it.all { v -> v is JsonPrimitive } }?.map { text(it) }
        private fun objects(value: JsonElement?): List<JsonObject> =
            (value as? JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty()

        fun candidateMid(match: LiveMatch, channels: List<MatchSource>): String? {
            val competition = when (match.league.uppercase(Locale.ROOT)) { "NBA" -> "100000"; "CBA" -> "100008"; else -> return null }
            val ids = channels.mapNotNull { source ->
                val url = source.pageUrl.toHttpUrlOrNull() ?: return@mapNotNull null
                if (url.pathSegments.lastOrNull { it.isNotEmpty() } !in setOf("kbs", "vxt", "txf")) return@mapNotNull null
                url.queryParameter("id")?.takeIf { it.matches(Regex("^[0-9]{10,12}$")) }
            }.toSet()
            return ids.singleOrNull()?.let { "$competition:$it" }
        }

        fun matches(info: JsonObject, match: LiveMatch, mid: String, now: Long = System.currentTimeMillis()): Boolean {
            if (text(info["mid"]) != mid || setOf(text(info["leftName"]), text(info["rightName"])) != setOf(match.homeTeam, match.awayTeam)) return false
            val kickoff = MatchSchedule.kickoff(match.time, now)?.toEpochMilli() ?: return false
            val start = try { LocalDateTime.parse(text(info["startTime"]), kickoffFormat).atZone(shanghai).toInstant().toEpochMilli() }
                catch (_: Exception) { return false }
            return abs(start - kickoff) <= 30 * 60_000
        }

        fun parseStatistics(data: JsonObject, mid: String, now: Long = System.currentTimeMillis()): SportsSnapshot {
            val info = data["teamInfo"] as? JsonObject ?: throw invalid()
            val left = text(info["leftName"]); val right = text(info["rightName"])
            if (left.isEmpty() || right.isEmpty()) throw invalid()
            val tables = mutableListOf<SportsTable>()
            (data["periodGoals"] as? JsonObject)?.let { periods ->
                val headers = strings(periods["head"])
                val rows = (periods["rows"] as? JsonArray)?.mapNotNull { strings(it) }
                if (headers != null && rows?.size == 2 && rows.all { it.size == headers.size + 1 }) {
                    tables += SportsTable("分节得分", listOf("球队") + headers, listOf(left, right).zip(rows).map { (name, row) -> listOf(name) + row.drop(1) })
                }
            }
            val comparison = objects(data["teamStats"]).mapNotNull { stat ->
                val label = text(stat["text"]).takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                fun value(side: String): String {
                    val base = text(stat[side + "Val"], "—"); val extra = text(stat[side + "Ext"])
                    return if (extra.isEmpty()) base else "$base ($extra)"
                }
                listOf(label, value("left"), value("right"))
            }
            if (comparison.isNotEmpty()) tables += SportsTable("球队技术统计", listOf("项目", left, right), comparison)
            (data["playerStats"] as? JsonObject)?.let { players ->
                for ((side, name) in listOf("left" to left, "right" to right)) {
                    val entries = objects(players[side])
                    val headers = strings(entries.firstOrNull()?.get("head"))?.takeIf { it.isNotEmpty() } ?: continue
                    val rows = entries.mapNotNull { entry ->
                        val row = strings(entry["row"])?.takeIf { it.size == headers.size + 1 } ?: return@mapNotNull null
                        listOf(row.take(2).filter(String::isNotEmpty).joinToString(" ")) + row.drop(2)
                    }
                    if (rows.isNotEmpty()) tables += SportsTable("$name · 球员技术统计", headers, rows)
                }
            }
            fun badge(key: String) = text(info[key]).toHttpUrlOrNull()?.toString()
            return SportsSnapshot(mid, left, right, "${text(info["leftGoal"], "—")} : ${text(info["rightGoal"], "—")}",
                text(info["quarterDesc"]), tables, now, badge("leftBadge"), badge("rightBadge"))
        }

        fun parseComments(data: JsonObject, mid: String, now: Long = System.currentTimeMillis()): List<SportsComment> {
            val seen = HashSet<String>()
            return objects(data["list"]).mapNotNull { row ->
                val id = text(row["commentId"])
                if (text(row["mid"]) != mid || text(row["type"]) != "0" || id.isEmpty() || !seen.add(id)) return@mapNotNull null
                val seconds = text(row["postTime"]).toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 && it < Long.MAX_VALUE / 1_000.0 } ?: return@mapNotNull null
                val posted = (seconds * 1_000).toLong()
                if (now - posted >= 120_000 || posted - now >= 30_000) return@mapNotNull null
                val message = text(row["content"]).replace(Regex("\\[[^\\]]{1,30}/\\]"), "")
                    .replace(Regex("<[^>]*>"), "").filterNot(Char::isISOControl).trim()
                if (message.isEmpty()) return@mapNotNull null
                val end = message.offsetByCodePoints(0, minOf(80, message.codePointCount(0, message.length)))
                SportsComment(id, message.substring(0, end), posted)
            }.sortedBy { it.postedAt }
        }
    }
}

/** Pure presentation math shared with the Apple comparison chart. */
data class SportsStatComparison(val left: Double, val right: Double) {
    val leftShare: Float get() = if (left + right == 0.0) 0.5f else (left / (left + right)).toFloat()
    companion object {
        fun from(row: List<String>): SportsStatComparison? {
            fun number(text: String?) = text?.let { Regex("^\\s*([0-9]+(?:\\.[0-9]+)?)").find(it)?.groupValues?.get(1)?.toDoubleOrNull() }?.takeIf { it.isFinite() }
            val left = number(row.getOrNull(1)) ?: return null
            val right = number(row.getOrNull(2)) ?: return null
            return SportsStatComparison(left, right)
        }
    }
}
