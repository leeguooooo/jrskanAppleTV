package com.leeguoo.jrkan.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import org.mozilla.javascript.Context
import org.mozilla.javascript.ContextFactory
import org.mozilla.javascript.Scriptable
import org.mozilla.javascript.ScriptableObject
import java.io.ByteArrayOutputStream
import kotlin.coroutines.cancellation.CancellationException

/**
 * Port of StreamResolver (App/Sources/Shared/StreamResolver.swift): walks a
 * source page through nested players until it reaches a playable HLS URL.
 *
 * The Swift version runs the site's player scripts in JavaScriptCore; here
 * they run in Mozilla Rhino in interpreted mode (Android cannot load the
 * bytecode Rhino's optimizer generates at runtime).
 *
 * [trace] receives one line per step; tests and diagnostics use it to see
 * which path a resolution took. It defaults to a no-op.
 */
class StreamResolver(
    private val client: OkHttpClient = Http.client,
    val maximumDepth: Int = 6,
    private val trace: (String) -> Unit = {},
) {
    suspend fun resolve(sourcePageUrl: String): String {
        val url = sourcePageUrl.toHttpUrlOrNull()
            ?: throw JrsException(JrsException.Kind.StreamPageUnavailable)
        return resolve(url, Http.HOMEPAGE, 0, HashSet()).toString()
    }

    fun extractM3U8Url(html: String, pageUrl: String): String? =
        pageUrl.toHttpUrlOrNull()?.let { extractM3U8Urls(html, it).firstOrNull()?.toString() }

    private fun extractM3U8Urls(html: String, pageUrl: HttpUrl): List<HttpUrl> {
        val decoded = decodeHtmlEntities(html)
        restoredPlayerUrl(decoded, pageUrl)?.let { return listOf(it) }
        val directPatterns = listOf(
            """(?i)(?:src|file|url|m3u8Url)\s*[:=]\s*["']([^"'<>\s]+\.m3u8[^"'<>\s]*)["']""",
            """(?i)(https?://[^"'<>\\\s]+\.m3u8[^"'<>\\\s]*)""",
            """(?i)(//[^"'<>\\\s]+\.m3u8[^"'<>\\\s]*)""",
        )

        val candidates = LinkedHashSet<HttpUrl>()
        for (pattern in directPatterns) {
            decoded.regexCaptures(pattern)
                .mapNotNull { it.getOrNull(1) }
                .mapNotNull { makeUrl(it, pageUrl) }
                .filter(::isM3U8Url)
                .forEach { candidates.add(it) }
        }
        if (candidates.isNotEmpty()) return candidates.toList()

        // Some player wrappers build the stream as a fixed host plus the
        // current page's `id` query value.
        val hostPatterns = listOf(
            """(?is)(?:const|let|var)\s+\w*[Uu]rl\s*=\s*["']((?:https?:)?//[^"']+)["']\s*\+\s*id""",
        )
        val streamPath = idQuerySuffix(pageUrl)?.let(::percentDecode) ?: return emptyList()
        if (!streamPath.contains(".m3u8", ignoreCase = true)) return emptyList()

        for (pattern in hostPatterns) {
            val host = decoded.regexCaptures(pattern).firstOrNull()?.getOrNull(1) ?: continue
            makeUrl(host + streamPath, pageUrl)?.let { return listOf(it) }
        }
        return emptyList()
    }

    /**
     * The msss wrapper reverses the second-level domain in its `id` value.
     * Match that specific player contract rather than treating every wrapper
     * query containing .m3u8 as media (or reversing ordinary stream hosts).
     */
    private fun restoredPlayerUrl(html: String, pageUrl: HttpUrl): HttpUrl? {
        if (!html.regexContains("""\brestoreStreamUrl\s*\(\s*id\s*\)""")) return null
        if (!html.regexContains("""\.split\(\s*["']["']\s*\)\s*\.reverse\(\s*\)\s*\.join\(\s*["']["']\s*\)""")) {
            return null
        }
        // J_get consumes the entire suffix, including unescaped '&' and '='
        // belonging to the media URL's signed query. Decode it exactly once.
        val rawValue = idQuerySuffix(pageUrl) ?: return null
        val value = percentDecode(rawValue) ?: rawValue
        val url = makeUrl(value, pageUrl) ?: return null
        if (!isM3U8Url(url)) return null
        val lower = value.lowercase()
        if (!(value.startsWith("//") || lower.startsWith("https://") || lower.startsWith("http://"))) return null

        val labels = url.host.split(".").toMutableList()
        if (labels.size < 2 || labels.any { it.isEmpty() }) return null
        labels[labels.size - 2] = labels[labels.size - 2].reversed()
        // The wrapper returns a protocol-relative URL even for an http input.
        return try {
            url.newBuilder().scheme("https").host(labels.joinToString(".")).build()
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    fun iframeUrls(html: String, pageUrl: String): List<String> =
        pageUrl.toHttpUrlOrNull()?.let { iframeUrls(html, it).map(HttpUrl::toString) } ?: emptyList()

    private fun iframeUrls(html: String, pageUrl: HttpUrl): List<HttpUrl> {
        val decoded = decodeHtmlEntities(html)
        val urls = decoded.regexCaptures("""(?is)<iframe[^>]+src\s*=\s*["']([^"']+)["']""")
            .mapNotNull { it.getOrNull(1) }
            .filter { !it.endsWith("/play/") }
            .mapNotNull { makeUrl(it, pageUrl) }
            .toMutableList()

        val buildsPlayerPath = decoded.regexContains("""(?is)src\s*=\s*['"]/play/['"]\s*\+\s*id1\s*\+\s*['"]\.html""")
        if (buildsPlayerPath) {
            val id = rawQueryValue(pageUrl, "id")
            if (id != null && id.regexContains("^[A-Za-z0-9_-]+$")) {
                pageUrl.resolve("/play/$id.html")?.let { urls.add(it) }
            }
        }
        return urls.distinct()
    }

    private suspend fun resolve(
        pageUrl: HttpUrl,
        referer: String,
        depth: Int,
        visited: MutableSet<HttpUrl>,
    ): HttpUrl {
        if (depth > maximumDepth) throw JrsException(JrsException.Kind.TooManyRedirects)
        currentCoroutineContext().ensureActive()
        if (isM3U8Url(pageUrl)) return validateStream(pageUrl)
        if (!visited.add(pageUrl)) throw JrsException(JrsException.Kind.NoPlayableStream)

        trace("page $pageUrl (depth $depth)")
        val page = fetchPage(pageUrl, referer)
        val html = page.first
        val effectiveUrl = page.second
        if (html.trim().startsWith("#EXTM3U")) {
            if (!hasMediaEntries(html)) throw JrsException(JrsException.Kind.UnavailableStream)
            return effectiveUrl
        }
        var lastError: Exception = JrsException(JrsException.Kind.NoPlayableStream)
        for (streamUrl in extractM3U8Urls(html, effectiveUrl)) {
            try {
                return validateStream(streamUrl)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                currentCoroutineContext().ensureActive()
                lastError = e
            }
        }
        try {
            encryptedHlsUrl(html, effectiveUrl)?.let { return validateStream(it) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            currentCoroutineContext().ensureActive()
            lastError = e
        }

        val nestedPlayerUrls = iframeUrls(html, effectiveUrl).toMutableList()
        try {
            val generated = generatedIframeUrl(html, effectiveUrl)
            if (generated != null && generated !in nestedPlayerUrls) nestedPlayerUrls.add(generated)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            currentCoroutineContext().ensureActive()
            lastError = e
        }

        for (iframeUrl in nestedPlayerUrls) {
            try {
                return resolve(iframeUrl, effectiveUrl.toString(), depth + 1, visited)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                currentCoroutineContext().ensureActive()
                lastError = e
            }
        }
        throw lastError
    }

    /** Runs the site's pjs.js against `encodedStr` and reads the iframe it writes. */
    fun generatedIframeUrl(html: String, playerScript: String, pageUrl: String): String? {
        val page = pageUrl.toHttpUrlOrNull() ?: return null
        return generatedIframeUrl(html, playerScript, page)?.toString()
    }

    private fun generatedIframeUrl(html: String, playerScript: String, pageUrl: HttpUrl): HttpUrl? {
        val encodedValue = html.regexCaptures("""(?is)var\s+encodedStr\s*=\s*["']([^"']+)["']""")
            .firstOrNull()?.getOrNull(1) ?: return null
        val generatedHtml = Js.run({ trace("rhino error in pjs.js: $it") }) { context, scope ->
            ScriptableObject.putProperty(scope, "encodedStr", encodedValue)
            context.evaluateString(
                scope,
                """
                var __playerElement = { innerHTML: "" };
                var navigator = { userAgent: "iPhone" };
                var document = {
                  getElementById: function() { return __playerElement; }
                };
                """.trimIndent(),
                "prelude",
                1,
                null,
            )
            context.evaluateString(scope, playerScript, "pjs.js", 1, null)
            val element = ScriptableObject.getProperty(scope, "__playerElement") as? Scriptable
                ?: return@run null
            Context.toString(ScriptableObject.getProperty(element, "innerHTML"))
        } ?: return null
        trace("rhino pjs.js wrote ${generatedHtml.take(200)}")
        return iframeUrls(generatedHtml, pageUrl).firstOrNull()
    }

    /** Runs index.min.js plus the page script and calls `decryptUrlWithExpiry`. */
    fun evaluateEncryptedHlsUrl(libraryScript: String, pageScript: String, pageUrl: String): String? {
        val rawValue = Js.run({ trace("rhino error in decrypt path: $it") }) { context, scope ->
            ScriptableObject.putProperty(scope, "__pageURL", pageUrl)
            context.evaluateString(
                scope,
                """
                var window = this;
                var self = this;
                var document = {
                  location: { href: __pageURL },
                  referrer: "",
                  cookie: "",
                  getElementById: function() { return { innerHTML: "" }; },
                  write: function() {}
                };
                var navigator = { userAgent: "iPhone", maxTouchPoints: 0 };
                var console = {
                  log: function() {}, error: function() {}, warn: function() {},
                  info: function() {}, debug: function() {}, exception: function() {},
                  trace: function() {}
                };
                var setInterval = function() { return 0; };
                var setTimeout = function() { return 0; };
                var clearInterval = function() {};
                var clearTimeout = function() {};
                """.trimIndent(),
                "prelude",
                1,
                null,
            )
            context.evaluateString(scope, libraryScript, "index.min.js", 1, null)
            context.evaluateString(scope, pageScript, "page", 1, null)
            Context.toString(context.evaluateString(scope, "decryptUrlWithExpiry(encryptedBase64Str)", "call", 1, null))
        } ?: return null
        trace("rhino decryptUrlWithExpiry returned ${rawValue.take(200)}")
        val streamUrl = rawValue.toHttpUrlOrNull() ?: return null
        return if (isM3U8Url(streamUrl)) streamUrl.toString() else null
    }

    private suspend fun generatedIframeUrl(html: String, pageUrl: HttpUrl): HttpUrl? {
        if (!html.contains("encodedStr")) return null
        val rawScriptUrl = html.regexCaptures("""(?is)<script[^>]+src\s*=\s*["']([^"']*pjs\.js[^"']*)["']""")
            .firstOrNull()?.getOrNull(1) ?: return null
        val scriptUrl = makeUrl(rawScriptUrl, pageUrl) ?: return null
        val playerScript = fetchPage(scriptUrl, pageUrl.toString()).first
        trace("rhino path: pjs.js from $scriptUrl")
        return withContext(Dispatchers.Default) { generatedIframeUrl(html, playerScript, pageUrl) }
    }

    private suspend fun encryptedHlsUrl(html: String, pageUrl: HttpUrl): HttpUrl? {
        val pageScript = html.regexCaptures("""(?is)<script(?:\s[^>]*)?>(.*?)</script>""")
            .mapNotNull { it.getOrNull(1) }
            .firstOrNull { it.contains("decryptUrlWithExpiry") }

        if (!html.contains("decryptUrlWithExpiry")) return null
        val rawLibraryUrl = html.regexCaptures("""(?is)<script[^>]+src\s*=\s*["']([^"']*index\.min\.js[^"']*)["']""")
            .firstOrNull()?.getOrNull(1) ?: return null
        val libraryUrl = makeUrl(rawLibraryUrl, pageUrl) ?: return null
        if (pageScript == null) return null

        val libraryScript = fetchPage(libraryUrl, pageUrl.toString()).first
        trace("rhino path: index.min.js from $libraryUrl")
        return withContext(Dispatchers.Default) {
            evaluateEncryptedHlsUrl(libraryScript, pageScript, pageUrl.toString())?.toHttpUrlOrNull()
        }
    }

    private suspend fun fetchPage(url: HttpUrl, referer: String): Pair<String, HttpUrl> {
        val page = Http.get(url.toString(), referer = referer, client = client)
        if (page.status !in 200 until 400) throw JrsException(JrsException.Kind.StreamPageUnavailable)
        return page.utf8OrLatin1() to (page.finalUrl.toHttpUrlOrNull() ?: url)
    }

    /**
     * Reject an expired URL or HTML error page before opening a black player.
     * Successful parsing alone says nothing about the origin's availability.
     */
    private suspend fun validateStream(url: HttpUrl): HttpUrl {
        trace("validate $url")
        val page = Http.get(url.toString(), timeoutSeconds = 10, client = client)
        val text = page.utf8()
        if (page.status !in 200 until 300 || text == null ||
            !text.trim().startsWith("#EXTM3U") || !hasMediaEntries(text)
        ) {
            throw JrsException(JrsException.Kind.UnavailableStream)
        }
        return page.finalUrl.toHttpUrlOrNull() ?: url
    }

    private fun hasMediaEntries(text: String): Boolean =
        text.contains("#EXTINF:") || text.contains("#EXT-X-STREAM-INF:") || text.contains("#EXT-X-PART:")

    private fun makeUrl(rawValue: String, pageUrl: HttpUrl): HttpUrl? {
        val cleaned = rawValue.replace("\\/", "/").replace("&amp;", "&").trim()
        // resolveUrl only yields http(s) URLs, the scheme filter Swift applies here.
        return resolveUrl(cleaned, pageUrl)
    }

    private fun isM3U8Url(url: HttpUrl): Boolean =
        url.pathSegments.joinToString("/").lowercase().endsWith(".m3u8")

    private fun decodeHtmlEntities(value: String): String =
        value.replace("\\/", "/")
            .replace("\\u0026", "&", ignoreCase = true)
            .replace("&amp;", "&")
            .replace("&quot;", "\"")
            .replace("&#39;", "'")

    /** The percent-encoded query from the first `id=` to the end. */
    private fun idQuerySuffix(url: HttpUrl): String? {
        val query = url.encodedQuery ?: return null
        val matcher = compiledPattern("(?:^|&)id=").matcher(query)
        if (!matcher.find()) return null
        return query.substring(matcher.end())
    }

    /** `URLComponents.queryItems.first { $0.name == name }.value` (no '+' → space). */
    private fun rawQueryValue(url: HttpUrl, name: String): String? {
        val query = url.encodedQuery ?: return null
        for (item in query.split("&")) {
            val parts = item.split("=", limit = 2)
            if (percentDecode(parts[0]) == name) return percentDecode(parts.getOrElse(1) { "" })
        }
        return null
    }

    /**
     * Rhino plumbing. Each evaluation gets a fresh context and global scope;
     * any JS error yields null (Swift checks `context.exception`). Scripts
     * that run longer than [SCRIPT_BUDGET_MS] are aborted — JavaScriptCore had
     * no such guard, but a hung interpreter cannot be cancelled otherwise.
     */
    private object Js {
        private const val SCRIPT_BUDGET_MS = 10_000L
        private const val MAX_STACK_DEPTH = 2_000
        private const val DEADLINE_KEY = "jrkan.deadline"

        private val factory = object : ContextFactory() {
            override fun makeContext(): Context = super.makeContext().apply {
                isInterpretedMode = true
                languageVersion = Context.VERSION_ES6
                instructionObserverThreshold = 100_000
                // jsjiami-obfuscated player pages (paps.html) open with an
                // anti-debug function that recurses forever inside try/catch.
                // JavaScriptCore overflows its stack, throws a RangeError and
                // the page carries on; Rhino's interpreter keeps frames on the
                // heap and would recurse until the budget below. A depth cap
                // restores the catchable overflow.
                maximumInterpreterStackDepth = MAX_STACK_DEPTH
            }

            override fun observeInstructionCount(cx: Context, instructionCount: Int) {
                val deadline = cx.getThreadLocal(DEADLINE_KEY) as? Long ?: return
                if (System.currentTimeMillis() > deadline) throw Error("script budget exceeded")
            }
        }

        fun <T> run(onError: (Throwable) -> Unit, block: (Context, Scriptable) -> T?): T? {
            val context = factory.enterContext()
            return try {
                context.putThreadLocal(DEADLINE_KEY, System.currentTimeMillis() + SCRIPT_BUDGET_MS)
                // Safe objects: the standard JS library without LiveConnect, so
                // page scripts cannot reach Java classes.
                val scope = context.initSafeStandardObjects()
                block(context, scope)
            } catch (e: Throwable) {
                onError(e)
                null
            } finally {
                Context.exit()
            }
        }
    }
}

/**
 * `removingPercentEncoding`: decodes every %XX, leaves '+' alone, and returns
 * null for a malformed escape or bytes that are not UTF-8.
 */
internal fun percentDecode(value: String): String? {
    if (!value.contains('%')) return value
    val out = ByteArrayOutputStream(value.length)
    var index = 0
    while (index < value.length) {
        if (value[index] == '%') {
            if (index + 2 >= value.length) return null
            val high = Character.digit(value[index + 1], 16)
            val low = Character.digit(value[index + 2], 16)
            if (high < 0 || low < 0) return null
            out.write(high * 16 + low)
            index += 3
        } else {
            val next = value.indexOf('%', index).let { if (it < 0) value.length else it }
            out.write(value.substring(index, next).toByteArray(Charsets.UTF_8))
            index = next
        }
    }
    return Http.decodeUtf8Strict(out.toByteArray())
}
