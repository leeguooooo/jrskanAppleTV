package com.leeguoo.jrkan.data

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.regex.Pattern

/**
 * Kotlin port of JRSListingParser (App/Sources/Shared/JRSListingParser.swift).
 *
 * Regex note: the Swift side uses NSRegularExpression (ICU). On Android,
 * java.util.regex is also ICU-backed, so behaviour matches on device; the JVM
 * unit tests run the JDK engine, whose `\s`/`\w` are ASCII-only. The patterns
 * below are the Swift ones verbatim except where noted.
 */
class JrsListingParser {
    /**
     * The homepage no longer writes channel URLs into the listing. Each anchor
     * carries `href="' + getPlayUrl("line1", "821720") + '"` and the hosts
     * behind `line1…lineN` live in a `PLAY_HOSTS` map on the homepage, base64
     * encoded. Pass the decoded map so those anchors resolve to real pages.
     */
    fun parse(
        script: String,
        relativeTo: String,
        playHosts: Map<String, String> = emptyMap(),
    ): List<LiveMatch> {
        val baseUrl = relativeTo.toHttpUrlOrNull()
        val html = decodeDocumentWrites(script)
        val blocks = html.regexCaptures(
            """(?is)(<ul\s+class="item\s+play[^"]*"[^>]*data-lid="([^"]+)"[^>]*>.*?</ul>)""",
        )

        val matches = blocks.mapNotNull { captures ->
            if (captures.size < 3) return@mapNotNull null
            val block = captures[1]
            val dataId = captures[2]
            val league = firstText(
                block,
                """(?is)<li\s+class="lab_events"[^>]*>.*?<span\s+class="name">(.+?)</span>""",
            )
            val time = firstText(block, """(?is)<li\s+class="lab_time"[^>]*>(.+?)</li>""")
            val teams = block.regexCaptures(
                """(?is)<li\s+class="lab_team_(?:home|away)"[^>]*>.*?<strong\s+class="name">(.+?)</strong>.*?<img[^>]+src="([^"]*)""",
            )

            if (teams.size < 2) return@mapNotNull null
            val homeTeam = cleanHtml(teams[0][1])
            val awayTeam = cleanHtml(teams[1][1])
            if (league.isEmpty() || homeTeam.isEmpty() || awayTeam.isEmpty()) return@mapNotNull null

            val sources = parseSources(block, baseUrl, dataId, playHosts)
            LiveMatch(
                id = dataId,
                league = league,
                time = time,
                homeTeam = homeTeam,
                awayTeam = awayTeam,
                // Swift's URL(string:) keeps any non-empty value as-is.
                homeLogoUrl = cleanHtml(teams[0][2]).ifEmpty { null },
                awayLogoUrl = cleanHtml(teams[1][2]).ifEmpty { null },
                isHot = block.regexContains("""class="[^"]*\bhot\b"""),
                sources = sources,
            )
        }

        if (matches.isEmpty()) throw JrsException(JrsException.Kind.NoMatches)
        return matches
    }

    private fun decodeDocumentWrites(script: String): String {
        // `href="' + getPlayUrl("line1", "821720") + '"` splits one write into
        // two string literals with a call in between. Fold the call back into
        // the literal as a `getPlayUrl:line1:821720` token first, so the anchor
        // survives decoding with its line and id attached.
        val folded = script.regexReplace(
            """'\s*\+\s*getPlayUrl\(\s*["'](\w+)["']\s*,\s*["']([A-Za-z0-9_-]+)["']\s*\)\s*\+\s*'""",
            "getPlayUrl:$1:$2",
        )
        // Swift: `'((?:\\'|[^'])*)'`. The JDK engine recurses once per
        // iteration of an alternation loop and overflows on long writes, so
        // this is the same language written as `(?:[^'\\]++|\\'?)*`: runs of
        // ordinary characters, an escaped quote, or a lone backslash.
        return folded.regexCaptures("""(?is)document\.write\(\s*'((?:[^'\\]++|\\'?)*)'\s*\)\s*;?""")
            .mapNotNull { if (it.size > 1) it[1] else null }
            .joinToString("\n") { it.replace("\\'", "'").replace("\\/", "/") }
    }

    private fun parseSources(
        block: String,
        baseUrl: HttpUrl?,
        matchId: String,
        playHosts: Map<String, String>,
    ): List<MatchSource> {
        val anchors = block.regexCaptures("""(?is)<a\s+([^>]*class="[^"]*\bok\b[^"]*"[^>]*)>(.*?)</a>""")

        val seen = HashSet<String>()
        return anchors.withIndex().mapNotNull { (offset, captures) ->
            if (captures.size < 3) return@mapNotNull null
            val attributes = captures[1]
            val innerHtml = captures[2]
            val dataPlay = attribute("data-play", attributes)
            val href: String? = if (attributes.contains("getPlayUrl:")) {
                // A generated link whose line has no host on the homepage is
                // the site's own dead entry; its `data-play` is just ".html".
                generatedPlayUrl(attributes, playHosts) ?: return@mapNotNull null
            } else {
                attribute("href", attributes)
            }
            // The public link is the route that can be opened independently.
            // `data-play` is often an older mirror consumed only by site JS.
            val rawUrl = listOfNotNull(href, dataPlay).firstOrNull {
                it.isNotEmpty() && !it.startsWith("javascript:") && !it.contains("getPlayUrl")
            } ?: return@mapNotNull null
            val pageUrl = resolveUrl(rawUrl, baseUrl)?.toString() ?: return@mapNotNull null
            if (!seen.add(pageUrl)) return@mapNotNull null

            val label = firstText(innerHtml, """(?is)<strong[^>]*>(.+?)</strong>""")
            MatchSource(
                id = "$matchId-$offset-$pageUrl",
                name = label.ifEmpty { "线路 ${offset + 1}" },
                pageUrl = pageUrl,
            )
        }
    }

    /**
     * `href="getPlayUrl:line1:821720"` (the folded form of the site's
     * `getPlayUrl("line1", "821720")`) → `<host>/play/steam821720.html`.
     */
    private fun generatedPlayUrl(attributes: String, playHosts: Map<String, String>): String? {
        val captures = attributes.regexCaptures("""getPlayUrl:(\w+):([A-Za-z0-9_-]+)""").firstOrNull()
            ?: return null
        if (captures.size < 3) return null
        val host = playHosts[captures[1]] ?: return null
        return "$host/play/steam${captures[2]}.html"
    }

    private fun attribute(name: String, attributes: String): String? =
        attributes.regexCaptures("""${Pattern.quote(name)}="([^"]*)"""").firstOrNull()?.getOrNull(1)
            ?.let(::cleanHtml)

    private fun firstText(text: String, pattern: String): String {
        val value = text.regexCaptures(pattern).firstOrNull()?.getOrNull(1) ?: return ""
        return cleanHtml(value)
    }

    companion object {
        /**
         * Decodes the homepage's `window.PLAY_HOSTS = { line1: atob("…"), … }`
         * table into `{"line1": "http://play.example", …}`.
         */
        fun playHosts(homepageHtml: String): Map<String, String> {
            val hosts = LinkedHashMap<String, String>()
            for (captures in homepageHtml.regexCaptures("""(?s)(\w+)\s*:\s*atob\(\s*["']([A-Za-z0-9+/=]+)["']\s*\)""")) {
                if (captures.size < 3) continue
                val bytes = decodeBase64Strict(captures[2]) ?: continue
                val host = Http.decodeUtf8Strict(bytes)?.trim() ?: continue
                if (host.isEmpty()) continue
                hosts[captures[1]] = host
            }
            return hosts
        }
    }
}

/**
 * Port of SourcePageParser: the second-level channel buttons of a source page.
 */
class SourcePageParser {
    fun parse(html: String, relativeTo: String): List<MatchSource> {
        val pageUrl = relativeTo.toHttpUrlOrNull()
        val uncommentedHtml = html.regexReplace("""(?is)<!--.*?-->""", "")
        val channelBlocks = uncommentedHtml.regexCaptures(
            """(?is)<div\s+[^>]*class=["'][^"']*\bsub_channel\b[^"']*["'][^>]*>(.*?)</div>""",
        )
        val scope = channelBlocks.firstOrNull()?.getOrNull(1) ?: uncommentedHtml
        val anchors = scope.regexCaptures(
            """(?is)<a\s+([^>]*class=["'][^"']*\bok\b[^"']*["'][^>]*)>(.*?)</a>""",
        )

        val seen = HashSet<String>()
        return anchors.withIndex().mapNotNull { (offset, captures) ->
            if (captures.size < 3) return@mapNotNull null
            val attributes = captures[1]
            val innerHtml = captures[2]
            // Placeholder anchors carry `data-play="=&id2="` — query fragments
            // with no path, which would otherwise resolve to a bogus page URL.
            val rawUrl = listOfNotNull(attribute("data-play", attributes), attribute("href", attributes))
                .firstOrNull {
                    it.isNotEmpty() && !it.startsWith("=") && !it.startsWith("&") &&
                        !it.startsWith("javascript:")
                } ?: return@mapNotNull null
            val resolved = resolveUrl(rawUrl, pageUrl)?.toString() ?: return@mapNotNull null
            if (!seen.add(resolved)) return@mapNotNull null

            val label = innerHtml.regexCaptures("""(?is)<strong[^>]*>(.+?)</strong>""")
                .firstOrNull()?.getOrNull(1)?.let(::cleanHtml) ?: ""
            MatchSource(
                id = "channel-$offset-$resolved",
                name = label.ifEmpty { "频道 ${offset + 1}" },
                pageUrl = resolved,
            )
        }
    }

    private fun attribute(name: String, attributes: String): String? =
        attributes.regexCaptures("""${Pattern.quote(name)}=["']([^"']*)["']""").firstOrNull()?.getOrNull(1)
            ?.let(::cleanHtml)
}

// ---------------------------------------------------------------------------
// Shared helpers (the Swift `String.regexCaptures` extension and friends).

private val patternCache = ConcurrentHashMap<String, Pattern>()

internal fun compiledPattern(pattern: String): Pattern =
    patternCache.getOrPut(pattern) { Pattern.compile(pattern) }

/** Every match, each as [whole, group1, …]; unmatched groups become "". */
fun String.regexCaptures(pattern: String): List<List<String>> {
    val matcher = compiledPattern(pattern).matcher(this)
    val result = ArrayList<List<String>>()
    while (matcher.find()) {
        result += (0..matcher.groupCount()).map { matcher.group(it) ?: "" }
    }
    return result
}

/** `range(of:options:.regularExpression) != nil`. */
fun String.regexContains(pattern: String): Boolean = compiledPattern(pattern).matcher(this).find()

/** `replacingOccurrences(of:with:options:.regularExpression)`; `$1` templates as in ICU. */
fun String.regexReplace(pattern: String, template: String): String =
    compiledPattern(pattern).matcher(this).replaceAll(template)

internal fun cleanHtml(value: String): String =
    value.regexReplace("<[^>]+>", "")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
        .trim()

/**
 * `URL(string: raw, relativeTo: base)?.absoluteURL`, with "//host" → "https://host".
 * Only http(s) results exist as [HttpUrl]; every URL the app opens is one.
 */
internal fun resolveUrl(raw: String, base: HttpUrl?): HttpUrl? {
    if (raw.startsWith("//")) return "https:$raw".toHttpUrlOrNull()
    return raw.toHttpUrlOrNull() ?: base?.resolve(raw)
}

/** `Data(base64Encoded:)`: padding is required, unlike java.util.Base64. */
internal fun decodeBase64Strict(value: String): ByteArray? {
    if (value.length % 4 != 0) return null
    return try {
        Base64.getDecoder().decode(value)
    } catch (_: IllegalArgumentException) {
        null
    }
}
