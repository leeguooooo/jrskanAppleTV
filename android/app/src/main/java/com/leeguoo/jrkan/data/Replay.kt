package com.leeguoo.jrkan.data

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs

// Port of App/Sources/Shared/Replay/Replay.swift: full-game recordings fans
// upload to Weibo ("11月26日…NBA杯 热火vs76人全场回放"). Parsing and
// classification only; WeiboClient fetches.

/** One Weibo video post that looks like a match recording. Times are epoch millis. */
data class ReplayVideo(
    /** Weibo's short id (mblogid / bid), used to fetch fresh play links. */
    val id: String,
    val author: String,
    val authorId: String,
    val postedAt: Long,
    /** Plain text, links and "某某的微博视频" removed. */
    val text: String,
    val durationSeconds: Double,
    val coverUrl: String?,
    val matchup: Matchup?,
    val part: Part,
    /** Match day named in the title, Beijing midnight. */
    val titledDay: Long?,
) {
    sealed interface Part {
        data object Full : Part
        data object FirstHalf : Part
        data object SecondHalf : Part
        data class Period(val number: Int) : Part
        data object Other : Part

        val label: String
            get() = when (this) {
                Full -> "全场"
                FirstHalf -> "上半场"
                SecondHalf -> "下半场"
                is Period -> "第${CHINESE_DIGITS[number] ?: number.toString()}节"
                Other -> "片段"
            }

        /** Display order inside one game: whole game, halves, quarters, the rest. */
        val order: Int
            get() = when (this) {
                Full -> 0
                FirstHalf -> 1
                SecondHalf -> 2
                is Period -> 2 + number
                Other -> 100
            }
    }

    data class Matchup(val left: String, val right: String) {
        /** Order-free key in canonical names: 热火vs76人 and 76人vs热火 are one game. */
        val key: String get() = listOf(MultiSportsClient.canonical(left), MultiSportsClient.canonical(right)).sorted().joinToString("|")
    }

    /** The day the game belongs to: the title's date, else the posting day. */
    val gameDay: Long get() = titledDay ?: ReplayParsing.beijingDay(postedAt)

    /** The post text without hashtags, for a one-line title. */
    val title: String get() = ReplayParsing.collapse(text.replace(Regex("#[^#]{1,40}#"), " "))

    /** "全场 · 2:11:24 · 花查章" */
    val summary: String get() = "${part.label} · ${durationText(durationSeconds)} · $author"

    /** The post on Weibo, for 分享. */
    val shareUrl: String get() = if (authorId.isEmpty()) "https://m.weibo.cn/status/$id" else "https://weibo.com/$authorId/$id"

    /** "热火 vs 76人 · 全场" */
    val displayTitle: String get() = matchup?.let { "${it.left} vs ${it.right} · ${part.label}" } ?: title

    companion object {
        private val CHINESE_DIGITS = mapOf(1 to "一", 2 to "二", 3 to "三", 4 to "四")

        fun durationText(seconds: Double): String {
            val total = seconds.toInt()
            val h = total / 3600
            val m = total / 60 % 60
            val s = total % 60
            return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
        }
    }
}

/** Videos of one game from one or more uploaders. */
data class ReplayGroup(val matchup: ReplayVideo.Matchup, val day: Long, val videos: List<ReplayVideo>) {
    val id: String get() = "${matchup.key}@$day"
    val title: String get() = "${matchup.left} vs ${matchup.right}"
    val latestPost: Long get() = videos.maxOfOrNull { it.postedAt } ?: day

    /** "全场 · 上半场 · 下半场 · 5 个视频" */
    val partsSummary: String
        get() = videos.map { it.part.label }.distinct().take(4).joinToString(" · ") + " · ${videos.size} 个视频"

    /** "今天" / "昨天" / "11月24日", in Beijing days like the titles. */
    fun dayText(nowMillis: Long = System.currentTimeMillis()): String {
        val days = (ReplayParsing.beijingDay(nowMillis) - day) / 86_400_000L
        return when (days) {
            0L -> "今天"
            1L -> "昨天"
            else -> Instant.ofEpochMilli(day).atZone(ReplayParsing.beijing).let { "${it.monthValue}月${it.dayOfMonth}日" }
        }
    }
}

data class ReplayStream(val label: String, val url: String, val height: Int) {
    /** Weibo signs links for about an hour ("Expires=<unix seconds>"). */
    val expiresAt: Long? get() = Regex("[?&]Expires=(\\d+)").find(url)?.groupValues?.get(1)?.toLongOrNull()?.times(1000)
    val qualityLabel: String get() = when {
        height >= 1080 -> "1080P"
        height >= 720 -> "720P"
        height > 0 -> "${height}P"
        else -> label
    }
}

/** Remote-config knobs, see AppConfig.Replay. */
data class ReplayRules(val minDuration: Double = 600.0, val fullDuration: Double = 5400.0, val windowHours: Double = 48.0)

object ReplayParsing {
    val beijing: ZoneId = ZoneId.of("Asia/Shanghai")
    private val weiboDate = DateTimeFormatter.ofPattern("EEE MMM dd HH:mm:ss Z yyyy", Locale.US)

    /** "Thu Nov 26 09:05:37 +0800 2026"; null for anything else. */
    fun date(raw: String?): Long? =
        raw?.let { runCatching { ZonedDateTime.parse(it, weiboDate).toInstant().toEpochMilli() }.getOrNull() }

    fun beijingDay(millis: Long): Long =
        Instant.ofEpochMilli(millis).atZone(beijing).toLocalDate().atStartOfDay(beijing).toInstant().toEpochMilli()

    fun collapse(text: String): String = text.replace(Regex("\\s+"), " ").trim()

    /** m.weibo.cn sends HTML, weibo.com text_raw; both end up plain, link labels removed. */
    fun plainText(raw: String): String {
        var text = raw.replace(Regex("<br\\s*/?>"), " ")
        text = text.replace(Regex("<a[^>]*>(?:(?!</a>).)*?的微博视频(?:(?!</a>).)*?</a>"), " ")
        text = text.replace(Regex("<[^>]+>"), "")
        for ((entity, char) in listOf("&lt;" to "<", "&gt;" to ">", "&quot;" to "\"", "&#39;" to "'", "&nbsp;" to " ", "&amp;" to "&")) {
            text = text.replace(entity, char)
        }
        text = text.replace(Regex("https?://t\\.cn/\\S+"), " ")
        text = text.replace(Regex("\\S{1,30}的微博视频"), " ")
        text = text.replace("​", "")
        return collapse(text)
    }

    // Classification

    private val suffixWords = listOf("全场", "上半场", "下半场", "第", "录像", "回放", "高清", "中文", "英文", "比赛", "集锦", "精彩", "加时", "完整", "超清", "国语", "粤语", "解说")
    private val matchupPattern = Regex("([\\p{IsHan}A-Za-z0-9·]{1,16})\\s*(?:vs|VS|Vs|vS|V\\.S\\.|对阵)\\s*([\\p{IsHan}A-Za-z0-9·]{1,16})")

    /** "nba杯东部小组赛：热火vs76人 第二节回放" → 热火 / 76人. */
    fun matchup(text: String): ReplayVideo.Matchup? {
        val found = matchupPattern.find(text.replace("#", " ")) ?: return null
        var left = found.groupValues[1].split(Regex("[杯赛季日：:】」|｜]")).last()
        left = left.replace(Regex("^(?:NBA|nba|CBA|cba|WNBA)"), "")
        var right = found.groupValues[2]
        for (word in suffixWords) {
            val index = right.indexOf(word)
            if (index > 0) right = right.substring(0, index)
        }
        left = left.trim()
        right = right.trim()
        if (left.length !in 1..10 || right.length !in 1..10 || left == right) return null
        if (left.all(Char::isDigit) || right.all(Char::isDigit)) return null
        return ReplayVideo.Matchup(left, right)
    }

    fun part(text: String, duration: Double, rules: ReplayRules): ReplayVideo.Part {
        if ("上半场" in text) return ReplayVideo.Part.FirstHalf
        if ("下半场" in text) return ReplayVideo.Part.SecondHalf
        Regex("第\\s*([一二三四1-4])\\s*节").find(text)?.let { found ->
            val digit = found.groupValues[1]
            val n = digit.toIntOrNull() ?: mapOf("一" to 1, "二" to 2, "三" to 3, "四" to 4)[digit] ?: 0
            if (n > 0) return ReplayVideo.Part.Period(n)
        }
        if ("全场" in text || duration >= rules.fullDuration) return ReplayVideo.Part.Full
        return ReplayVideo.Part.Other
    }

    /** "11月26日" in the year that keeps it at or just before the posting time. */
    fun titledDay(text: String, postedAt: Long): Long? {
        val found = Regex("(\\d{1,2})月(\\d{1,2})日").find(text) ?: return null
        val month = found.groupValues[1].toInt()
        val day = found.groupValues[2].toInt()
        if (month !in 1..12 || day !in 1..31) return null
        val year = Instant.ofEpochMilli(postedAt).atZone(beijing).year
        var date = runCatching { ZonedDateTime.of(year, month, day, 0, 0, 0, 0, beijing) }.getOrNull() ?: return null
        if (date.toInstant().toEpochMilli() - postedAt > 2 * 86_400_000L) date = date.minusYears(1)
        return date.toInstant().toEpochMilli()
    }

    /** Long enough not to be a highlight, two teams named, labelled as a replay or game-length. */
    fun video(
        id: String, author: String, authorId: String, postedAt: Long, rawText: String,
        duration: Double, coverUrl: String?, rules: ReplayRules,
    ): ReplayVideo? {
        val text = plainText(rawText)
        if (duration < rules.minDuration) return null
        val matchup = matchup(text) ?: return null
        val labelled = listOf("回放", "录像", "全场", "半场", "节").any { it in text }
        if (!labelled && duration < rules.fullDuration) return null
        if (listOf("集锦", "盘点", "十佳", "五佳").any { it in text }) return null
        return ReplayVideo(
            id, author, authorId, postedAt, text, duration, coverUrl, matchup,
            part(text, duration, rules), titledDay(text, postedAt),
        )
    }

    // Response shapes

    private fun JsonElement?.obj() = this as? JsonObject
    private fun JsonElement?.str(): String? = (this as? JsonPrimitive)?.content?.takeIf { it.isNotEmpty() && it != "null" }
    private fun JsonElement?.num(): Double? = (this as? JsonPrimitive)?.let { it.doubleOrNull ?: it.content.toDoubleOrNull() }

    private fun https(raw: String?): String? {
        if (raw.isNullOrEmpty()) return null
        return when {
            raw.startsWith("http://") -> "https://" + raw.removePrefix("http://")
            raw.startsWith("//") -> "https:$raw"
            else -> raw
        }
    }

    /** One status from weibo.com/ajax (profile waterfall, statuses/show). */
    fun comVideo(status: JsonObject, rules: ReplayRules): ReplayVideo? {
        val page = status["page_info"].obj() ?: return null
        if (page["object_type"].str() != "video") return null
        val media = page["media_info"].obj() ?: return null
        val id = status["mblogid"].str() ?: return null
        val postedAt = date(status["created_at"].str()) ?: return null
        val duration = media["duration"].num() ?: return null
        val user = status["user"].obj()
        val cover = page["page_pic"].let { it.obj()?.get("url").str() ?: it.str() }
        return video(id, user?.get("screen_name").str().orEmpty(), user?.get("id").str().orEmpty(), postedAt,
            status["text_raw"].str().orEmpty(), duration, https(cover), rules)
    }

    /** One mblog from m.weibo.cn search. */
    fun cnVideo(mblog: JsonObject, rules: ReplayRules): ReplayVideo? {
        val page = mblog["page_info"].obj() ?: return null
        if (page["type"].str() != "video") return null
        val id = mblog["bid"].str() ?: return null
        val postedAt = date(mblog["created_at"].str()) ?: return null
        val duration = page["media_info"].obj()?.get("duration").num() ?: return null
        val user = mblog["user"].obj()
        return video(id, user?.get("screen_name").str().orEmpty(), user?.get("id").str().orEmpty(), postedAt,
            mblog["text"].str().orEmpty(), duration, https(page["page_pic"].obj()?.get("url").str()), rules)
    }

    data class Feed(val videos: List<ReplayVideo>, val nextCursor: String?)

    /** weibo.com/ajax/profile/getWaterFallContent → videos and the next cursor. */
    fun waterfall(root: JsonObject, rules: ReplayRules): Feed {
        val data = root["data"].obj()
        val list = (data?.get("list") as? JsonArray).orEmpty().mapNotNull { it.obj() }
        val cursor = data?.get("next_cursor").str()?.takeIf { it != "-1" && it != "0" }
        return Feed(list.mapNotNull { comVideo(it, rules) }, cursor)
    }

    /** m.weibo.cn search: mblogs sit in cards or card groups. */
    fun search(root: JsonObject, rules: ReplayRules): List<ReplayVideo> {
        val mblogs = mutableListOf<JsonObject>()
        fun walk(card: JsonObject) {
            card["mblog"].obj()?.let(mblogs::add)
            (card["card_group"] as? JsonArray).orEmpty().mapNotNull { it.obj() }.forEach(::walk)
        }
        (root["data"].obj()?.get("cards") as? JsonArray).orEmpty().mapNotNull { it.obj() }.forEach(::walk)
        return mblogs.mapNotNull { cnVideo(it, rules) }.distinctBy { it.id }
    }

    /** Playable MP4s from statuses/show, best first, 1080p and below; scrubber images and http dropped. */
    fun streams(status: JsonObject): List<ReplayStream> {
        val list = (status["page_info"].obj()?.get("media_info").obj()?.get("playback_list") as? JsonArray).orEmpty()
        val streams = list.mapNotNull { entry ->
            val e = entry.obj() ?: return@mapNotNull null
            val label = e["meta"].obj()?.get("label").str().orEmpty()
            val info = e["play_info"].obj()
            val url = info?.get("url").str()
            if (!label.startsWith("mp4") || url == null || !url.startsWith("https://")) return@mapNotNull null
            ReplayStream(label, url, info?.get("height").num()?.toInt() ?: 0)
        }
        val capped = streams.filter { it.height <= 1080 }
        return capped.ifEmpty { streams }.sortedByDescending { it.height }
    }

    // Grouping and matching

    /** Videos of the same teams within a day of each other become one game. */
    fun groups(videos: List<ReplayVideo>): List<ReplayGroup> {
        class Bucket(val matchup: ReplayVideo.Matchup, var day: Long, val videos: MutableList<ReplayVideo>)
        val buckets = mutableListOf<Bucket>()
        val seen = mutableSetOf<String>()
        for (video in videos.sortedByDescending { it.postedAt }) {
            if (!seen.add(video.id)) continue
            val matchup = video.matchup ?: continue
            val bucket = buckets.firstOrNull { it.matchup.key == matchup.key && abs(it.day - video.gameDay) <= 86_400_000L }
            if (bucket != null) {
                bucket.videos += video
                if (video.titledDay != null) bucket.day = video.gameDay
            } else {
                buckets += Bucket(matchup, video.gameDay, mutableListOf(video))
            }
        }
        return buckets.map { ReplayGroup(it.matchup, it.day, sortedForPlayback(it.videos)) }
            .sortedWith(compareByDescending<ReplayGroup> { it.day }.thenByDescending { it.latestPost })
    }

    /** Whole game first, then halves and quarters; same part: longest first, then earliest. */
    fun sortedForPlayback(videos: List<ReplayVideo>): List<ReplayVideo> = videos.sortedWith { a, b ->
        when {
            a.part.order != b.part.order -> a.part.order.compareTo(b.part.order)
            abs(a.durationSeconds - b.durationSeconds) > 60 -> b.durationSeconds.compareTo(a.durationSeconds)
            else -> a.postedAt.compareTo(b.postedAt)
        }
    }

    /**
     * Videos of this match: both teams agree, and the titled day (or the
     * posting time) fits the kickoff. Old seasons' meetings match the search
     * too, so the date check is not optional. A titled day may be posted up
     * to a week late (football uploads often are).
     */
    fun videos(home: String, away: String, kickoff: Long, videos: List<ReplayVideo>, rules: ReplayRules): List<ReplayVideo> {
        val key = ReplayVideo.Matchup(home, away).key
        val kickoffDay = beijingDay(kickoff)
        val window = (rules.windowHours * 3_600_000).toLong()
        val matched = videos.distinctBy { it.id }.filter { video ->
            if (video.matchup?.key != key) return@filter false
            if (video.postedAt < kickoff - 3_600_000L || video.postedAt > kickoff + window + 7 * 86_400_000L) return@filter false
            val titled = video.titledDay
            if (titled != null) abs(titled - kickoffDay) <= 86_400_000L else video.postedAt <= kickoff + window
        }
        return sortedForPlayback(matched)
    }
}
