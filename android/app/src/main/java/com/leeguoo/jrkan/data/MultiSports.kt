package com.leeguoo.jrkan.data

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*
import okhttp3.CookieJar
import okhttp3.OkHttpClient
import java.io.IOException
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/** Fixed priority is re-evaluated every poll. Video/account clients are never used. */
class MultiSportsClient(
    private val tencent: SportsDataProvider = TencentSportsClient(),
    private val client: OkHttpClient = OkHttpClient.Builder().cookieJar(CookieJar.NO_COOKIES).cache(null)
        .connectTimeout(8, TimeUnit.SECONDS).readTimeout(8, TimeUnit.SECONDS).callTimeout(12, TimeUnit.SECONDS).build(),
    private val clock: () -> Long = System::currentTimeMillis,
) : SportsDataProvider {
    private data class Context(val match: LiveMatch, val channels: List<MatchSource>)
    private val contexts = ConcurrentHashMap<String, Context>()
    private val miguIDs = ConcurrentHashMap<String, String>()
    private val espnIDs = ConcurrentHashMap<String, String>()
    private val verifiedTencent = ConcurrentHashMap.newKeySet<String>()
    private val catalogs = ConcurrentHashMap<String, Pair<Long, List<JsonObject>>>()

    override suspend fun prepare(match: LiveMatch, channels: List<MatchSource>): String? {
        if (match.league.uppercase() !in setOf("NBA", "CBA")) return null
        val key = "${match.league}|${match.homeTeam}|${match.awayTeam}|${match.time}"
        if (contexts.size > 20) { contexts.clear(); miguIDs.clear(); espnIDs.clear() }
        contexts[key] = Context(match, channels)
        return key
    }
    override suspend fun verify(match: LiveMatch, mid: String) { if (contexts[mid]?.match != match) throw invalid() }
    override suspend fun statistics(mid: String, match: LiveMatch): SportsSnapshot = fetchStatistics(mid, match) {}
    override suspend fun statistics(mid: String, match: LiveMatch, onPartial: suspend (SportsSnapshot) -> Unit): SportsSnapshot = fetchStatistics(mid, match, onPartial)
    private suspend fun fetchStatistics(mid: String, match: LiveMatch, onPartial: suspend (SportsSnapshot) -> Unit): SportsSnapshot {
        val context = contexts[mid] ?: throw invalid()
        val values = mutableListOf<SportsSnapshot>()
        TencentSportsClient.candidateMid(match, context.channels)?.let { id ->
            try {
                values += tencent.statistics(id, match)
                select(values)?.let { onPartial(it); if (complete(it)) return it }
            } catch (e: CancellationException) { throw e } catch (_: Exception) { currentCoroutineContext().ensureActive() }
        }
        try {
            val id = miguID(mid, match)
            values += miguStatistics(json("https://v0-sc.miguvideo.com/oes-sport-static/10/live/statistics/$id"), id, match, clock())
            select(values)?.let { onPartial(it); if (complete(it)) return it }
        } catch (e: CancellationException) { throw e } catch (_: Exception) { currentCoroutineContext().ensureActive() }
        try {
            val id = espnID(mid, match)
            values += espnStatistics(json("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=$id"), id, match, clock())
        } catch (e: CancellationException) { throw e } catch (_: Exception) { currentCoroutineContext().ensureActive() }
        return select(values) ?: throw invalid()
    }
    override suspend fun comments(mid: String): List<SportsComment> = fetchComments(mid, emptySet())
    override suspend fun comments(mid: String, excluding: Set<String>): List<SportsComment> = fetchComments(mid, excluding)
    private suspend fun fetchComments(mid: String, excluding: Set<String>): List<SportsComment> {
        val context = contexts[mid] ?: throw invalid()
        TencentSportsClient.candidateMid(context.match, context.channels)?.let { id ->
            try {
                val verificationKey = mid + id
                if (verificationKey !in verifiedTencent) {
                    tencent.verify(context.match, id)
                    if (verifiedTencent.size > 20) verifiedTencent.clear()
                    verifiedTencent += verificationKey
                }
                val rows = tencent.comments(id).map { it.copy(id = "tencent:${it.id}") }.filter { it.id !in excluding }
                if (rows.isNotEmpty()) return rows
            } catch (e: CancellationException) { throw e } catch (_: Exception) { currentCoroutineContext().ensureActive() }
        }
        val id = miguID(mid, context.match)
        return miguComments(json("https://webapi.miguvideo.com/gateway/interaction/v2/comment/1/20/$id/40/NEW?clientType=1"), id, clock()).filter { it.id !in excluding }
    }
    private suspend fun miguID(key: String, match: LiveMatch): String {
        miguIDs[key]?.let { return it }
        val page = if (match.league.uppercase() == "CBA") "494d21a4d6ee453b8b86bd3bb7658ed6" else "3cd6ba04967742879aaa40bee02a99a6"
        val rows = catalogs[page]?.takeIf { clock() - it.first < 300_000 }?.second ?: run {
            val html = bytes("https://www.miguvideo.com/p/home/$page")
            withContext(Dispatchers.Default) { catalogRows(html) }.also { catalogs[page] = clock() to it }
        }
        val ids = rows.filter { row ->
            text(row["competitionName"]).uppercase() == match.league.uppercase() &&
                matches(objects(row["teams"]).map { text(it["teamName"]) }, text(row["startTime"]), "yyyyMMddHHmm", match, clock()) && text(row["pID"]).matches(Regex("^[0-9]{12}$"))
        }.map { text(it["pID"]) }.toSet()
        val id = ids.singleOrNull() ?: throw invalid()
        miguIDs[key] = id
        return id
    }
    private suspend fun espnID(key: String, match: LiveMatch): String {
        espnIDs[key]?.let { return it }
        if (match.league.uppercase() != "NBA") throw invalid()
        val kickoff = MatchSchedule.kickoff(match.time, clock()) ?: throw invalid()
        val date = DateTimeFormatter.ofPattern("yyyyMMdd").withZone(ZoneId.of("America/New_York")).format(kickoff)
        val root = json("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=$date")
        val id = objects(root["events"]).filter { row -> objects(row["competitions"]).firstOrNull()?.let { espnMatch(it, match, clock()) } == true }
            .map { text(it["id"]) }.filter { it.matches(Regex("^[0-9]+$")) }.toSet().singleOrNull() ?: throw invalid()
        espnIDs[key] = id; return id
    }
    private suspend fun bytes(url: String): String {
        val page = Http.get(url, timeoutSeconds = 12, client = client)
        currentCoroutineContext().ensureActive()
        if (page.status != 200 || page.body.size > 4_000_000) throw invalid()
        return page.utf8() ?: throw invalid()
    }
    private suspend fun json(url: String): JsonObject {
        val body = bytes(url)
        return withContext(Dispatchers.Default) { Json.parseToJsonElement(body) as? JsonObject ?: throw invalid() }
    }

    companion object {
        private fun invalid() = IOException("本场比赛数据暂不可用")
        private fun text(value: JsonElement?, missing: String = ""): String = (value as? JsonPrimitive)?.takeUnless { it is JsonNull }?.content?.takeIf(String::isNotEmpty) ?: missing
        private fun obj(value: JsonElement?): JsonObject = value as? JsonObject ?: JsonObject(emptyMap())
        private fun objects(value: JsonElement?): List<JsonObject> = (value as? JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty()
        fun complete(value: SportsSnapshot) = value.periodTable != null && value.comparisonTable != null && value.playerTables.size == 2
        fun select(values: List<SportsSnapshot>): SportsSnapshot? {
            val first = values.firstOrNull() ?: return null
            val tables = mutableListOf<SportsTable>(); val used = HashSet<String>(); val sources = linkedSetOf(first.sourceName)
            for (value in values) {
                if (setOf(canonical(value.left), canonical(value.right)) != setOf(canonical(first.left), canonical(first.right))) continue
                for (original in value.tables) {
                    val kind = when (original.title) { "分节得分" -> "period"; "球队技术统计" -> "comparison"; else -> "player:" + canonical(original.title.substringBefore(" · ")) }
                    if (original.rows.none { row -> row.drop(1).any { it.isNotEmpty() && it != "—" } } || !used.add(kind)) continue
                    var table = original.copy(sourceName = value.sourceName)
                    if (canonical(value.left) != canonical(first.left)) {
                        if (kind == "comparison") table = table.copy(headers = listOf("项目", first.left, first.right), rows = table.rows.map { if (it.size == 3) listOf(it[0], it[2], it[1]) else it })
                        if (kind == "period") table = table.copy(rows = table.rows.reversed())
                    }
                    tables += table; sources += value.sourceName
                }
            }
            return first.copy(tables = tables, sourceName = sources.joinToString(" · "), scoreSourceName = first.sourceName)
        }
        private val aliases = mapOf("GS" to "勇士", "GSW" to "勇士", "LAL" to "湖人", "LAC" to "快船", "MEM" to "灰熊", "NY" to "尼克斯", "NYK" to "尼克斯", "NO" to "鹈鹕", "NOP" to "鹈鹕", "SA" to "马刺", "SAS" to "马刺", "UTAH" to "爵士", "UTA" to "爵士", "WSH" to "奇才", "WAS" to "奇才", "PHO" to "太阳", "PHX" to "太阳", "ATL" to "老鹰", "BOS" to "凯尔特人", "BKN" to "篮网", "CHA" to "黄蜂", "CHI" to "公牛", "CLE" to "骑士", "DAL" to "独行侠", "DEN" to "掘金", "DET" to "活塞", "HOU" to "火箭", "IND" to "步行者", "MIA" to "热火", "MIL" to "雄鹿", "MIN" to "森林狼", "OKC" to "雷霆", "ORL" to "魔术", "PHI" to "76人", "POR" to "开拓者", "SAC" to "国王", "TOR" to "猛龙", "布鲁克林篮网" to "篮网", "金州勇士" to "勇士", "洛杉矶湖人" to "湖人", "洛杉矶快船" to "快船", "灰熊队" to "灰熊")
        fun canonical(name: String): String = aliases[name.uppercase()] ?: aliases[name] ?: name
        fun matches(names: List<String>, start: String, format: String, match: LiveMatch, now: Long): Boolean {
            if (names.size != 2 || names.map(::canonical).toSet() != setOf(canonical(match.homeTeam), canonical(match.awayTeam))) return false
            val kickoff = MatchSchedule.kickoff(match.time, now)?.toEpochMilli() ?: return false
            val time = try { LocalDateTime.parse(start, DateTimeFormatter.ofPattern(format)).atZone(ZoneId.of("Asia/Shanghai")).toInstant().toEpochMilli() } catch (_: Exception) { return false }
            return abs(time - kickoff) <= 1_800_000
        }
        fun catalogRows(html: String): List<JsonObject> {
            val rows = mutableListOf<JsonObject>()
            fun walk(value: JsonElement) {
                when (value) {
                    is JsonObject -> { if (value["teams"] is JsonArray && value["pID"] != null) rows += value; value.values.forEach(::walk) }
                    is JsonArray -> value.forEach(::walk)
                    else -> Unit
                }
            }
            for (marker in listOf("__INITIAL_GROUPS_STATE__", "__INITIAL_COMPS_STATE__")) {
                val at = html.indexOf("window.$marker").takeIf { it >= 0 } ?: continue
                val begin = html.indexOf('{', at).takeIf { it >= 0 } ?: continue
                var depth = 0; var quoted = false; var escaped = false
                for (i in begin until html.length) {
                    val c = html[i]
                    if (quoted) { if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') quoted = false }
                    else if (c == '"') quoted = true
                    else if (c == '{') depth++
                    else if (c == '}') { depth--; if (depth == 0) { try { walk(Json.parseToJsonElement(html.substring(begin, i + 1))) } catch (_: IllegalArgumentException) {}; break } }
                }
            }
            return rows
        }
        fun miguStatistics(root: JsonObject, id: String, match: LiveMatch, now: Long): SportsSnapshot {
            val bkb = obj(root["BKB"]); val data = obj(bkb["matchData"]); val teams = obj(data["matchTeam"])
            val home = obj(teams["home"]); val away = obj(teams["guest"]); val names = listOf(text(home["teamName"]), text(away["teamName"]))
            if (text(root["code"]) != "200" || text(data["competitionShortName"]).uppercase() != match.league.uppercase() || !matches(names, text(data["matchDatetime"]), "yyyy-MM-dd HH:mm:ss", match, now)) throw invalid()
            val tables = mutableListOf<SportsTable>(); val quarters = objects(data["quarters"])
            if (quarters.isNotEmpty()) tables += SportsTable("分节得分", listOf("球队") + quarters.map { "第${text(it["quarter"])}节" }, listOf(listOf(names[0]) + quarters.map { text(it["homeScore"], "—") }, listOf(names[1]) + quarters.map { text(it["visitingScore"], "—") }))
            fun stat(o: JsonObject, key: String): String {
                val field = obj(o[key]); val value = text(field["value"], "—")
                return if (value != "—" && text(field["hasPercentType"]) == "1") "$value%" else value
            }
            val columns = listOf("points" to "得分", "rebounds" to "篮板", "assists" to "助攻", "steals" to "抢断", "blocks" to "盖帽", "turnovers" to "失误", "fieldGoalsPercentage" to "投篮命中率", "threePointPercentage" to "三分命中率", "trueShootingPct" to "真实命中率")
            val comparison = columns.map { (key, title) -> listOf(title, stat(obj(home["matchTeamStat"]), key), stat(obj(away["matchTeamStat"]), key)) }.filter { it[1] != "—" || it[2] != "—" }
            if (comparison.isNotEmpty()) tables += SportsTable("球队技术统计", listOf("项目") + names, comparison)
            val fields = listOf("seconds", "points", "rebounds", "assists", "steals", "blocks", "turnovers", "plusMinus", "trueShootingPct")
            for ((team, name) in listOf(home, away).zip(names)) {
                val teamID = text(team["wcTeamId"])
                val rows = objects(bkb["matchPlayerStatBeanList"]).filter { teamID.isNotEmpty() && text(it["wcTeamId"]) == teamID }.map { p ->
                    listOf(text(p["nickName"], "—")) + fields.map { key -> if (key == "seconds") stat(p, key).toIntOrNull()?.let { "${it / 60}:${(it % 60).toString().padStart(2, '0')}" } ?: "—" else stat(p, key) }
                }
                if (rows.isNotEmpty()) tables += SportsTable("$name · 球员技术统计", listOf("球员", "时间", "得分", "篮板", "助攻", "抢断", "盖帽", "失误", "+/-", "真实命中率"), rows)
            }
            return SportsSnapshot("migu:$id", names[0], names[1], "${text(home["teamScore"], "—")} : ${text(away["teamScore"], "—")}", "", tables, now, text(home["teamLogo"]).ifEmpty { null }, text(away["teamLogo"]).ifEmpty { null }, "咪咕视频")
        }
        fun miguComments(root: JsonObject, id: String, now: Long): List<SportsComment> {
            if (text(root["code"]) != "200") return emptyList()
            val seen = HashSet<String>()
            return objects(obj(root["body"])["commentInfoList"]).mapNotNull { row ->
                val cid = text(row["commentId"]); val posted = text(row["createTime"]).toLongOrNull() ?: return@mapNotNull null
                if (text(row["contentId"]) != id || text(row["objectId"]) != id || text(row["top"]) == "true" || cid.isEmpty() || !seen.add(cid) || now - posted >= 120_000 || posted - now >= 30_000) return@mapNotNull null
                val message = text(row["body"]).replace(Regex("<[^>]*>"), "").filterNot(Char::isISOControl).trim()
                if (message.isEmpty() || listOf("观赛群", "扫码", "http").any(message::contains)) return@mapNotNull null
                val end = message.offsetByCodePoints(0, minOf(80, message.codePointCount(0, message.length)))
                SportsComment("migu:$cid", message.substring(0, end), posted)
            }.sortedBy { it.postedAt }
        }
        fun espnMatch(comp: JsonObject, match: LiveMatch, now: Long): Boolean {
            val competitors = objects(comp["competitors"])
            if (competitors.size != 2 || competitors.map { canonical(text(obj(it["team"])["abbreviation"])) }.toSet() != setOf(canonical(match.homeTeam), canonical(match.awayTeam))) return false
            val kickoff = MatchSchedule.kickoff(match.time, now)?.toEpochMilli() ?: return false
            val time = try { OffsetDateTime.parse(text(comp["date"])).toInstant().toEpochMilli() } catch (_: Exception) { return false }
            return abs(time - kickoff) <= 1_800_000
        }
        fun espnStatistics(root: JsonObject, id: String, match: LiveMatch, now: Long): SportsSnapshot {
            val header = obj(root["header"]); val comp = objects(header["competitions"]).firstOrNull() ?: throw invalid()
            if (match.league.uppercase() != "NBA" || text(header["id"]) != id || !espnMatch(comp, match, now)) throw invalid()
            val competitors = objects(comp["competitors"]); val home = competitors.firstOrNull { text(it["homeAway"]) == "home" } ?: throw invalid(); val away = competitors.firstOrNull { text(it["homeAway"]) == "away" } ?: throw invalid()
            val teams = listOf(home, away); val names = teams.map { canonical(text(obj(it["team"])["abbreviation"])) }; val tables = mutableListOf<SportsTable>()
            val periods = teams.map { objects(it["linescores"]) }; val count = periods.maxOf { it.size }
            if (count > 0) tables += SportsTable("分节得分", listOf("球队") + (1..count).map { "第${it}节" }, names.zip(periods).map { (name, rows) -> listOf(name) + (0 until count).map { text(rows.getOrNull(it)?.get("displayValue"), "—") } })
            val box = obj(root["boxscore"]); val boxes = objects(box["teams"])
            val ordered = teams.map { team -> boxes.firstOrNull { text(obj(it["team"])["id"]) == text(team["id"]) } ?: JsonObject(emptyMap()) }
            val labels = mapOf("rebounds" to "篮板", "assists" to "助攻", "steals" to "抢断", "blocks" to "盖帽", "turnovers" to "失误", "fieldGoalPct" to "投篮命中率", "threePointFieldGoalPct" to "三分命中率", "freeThrowPct" to "罚球命中率")
            val teamRows = labels.keys.sorted().map { key -> listOf(labels.getValue(key)) + ordered.map { o -> text(objects(o["statistics"]).firstOrNull { text(it["name"]) == key }?.get("displayValue"), "—") } }.filter { it[1] != "—" || it[2] != "—" }
            if (teamRows.isNotEmpty()) tables += SportsTable("球队技术统计", listOf("项目") + names, teamRows)
            val translations = mapOf("MIN" to "时间", "PTS" to "得分", "REB" to "篮板", "AST" to "助攻", "STL" to "抢断", "BLK" to "盖帽", "TO" to "失误", "PF" to "犯规", "FG" to "投篮", "3PT" to "三分", "FT" to "罚球", "OREB" to "前板", "DREB" to "后板")
            for (team in objects(box["players"])) {
                val name = canonical(text(obj(team["team"])["abbreviation"])); if (name !in names) continue
                val group = objects(team["statistics"]).firstOrNull() ?: continue
                val headers = (group["labels"] as? JsonArray)?.map { text(it) } ?: continue
                val rows = objects(group["athletes"]).mapNotNull { row ->
                    val stats = (row["stats"] as? JsonArray)?.map { text(it, "—") } ?: return@mapNotNull null
                    if (stats.size != headers.size) return@mapNotNull null
                    listOf(text(obj(row["athlete"])["displayName"], "—")) + stats
                }
                if (rows.isNotEmpty()) tables += SportsTable("$name · 球员技术统计", listOf("球员") + headers.map { translations[it] ?: it }, rows)
            }
            val status = obj(obj(comp["status"])["type"])
            return SportsSnapshot("espn:$id", names[0], names[1], "${text(home["score"], "—")} : ${text(away["score"], "—")}", text(status["shortDetail"]), tables, now, sourceName = "ESPN")
        }
    }
}
