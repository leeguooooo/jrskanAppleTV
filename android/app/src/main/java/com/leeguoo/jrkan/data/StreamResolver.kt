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

    data class PlayerScriptResult(val url: String?, val requests: List<String>)

    fun playerScriptResult(html: String, playerScript: String, pageUrl: String,
                           responses: List<String> = emptyList()): PlayerScriptResult {
        val page = pageUrl.toHttpUrlOrNull() ?: return PlayerScriptResult(null, emptyList())
        if (playerScript.length > 512_000) return PlayerScriptResult(null, emptyList())
        fun value(pattern: String) = html.regexCaptures(pattern).firstOrNull()?.getOrNull(1)
        val encoded = value("""(?is)var\s+encodedStr\s*=\s*["']([^"']+)["']""")
        val config = value("""(?is)playerUrlBase64\s*:\s*["']([^"']+)["']""")
        val payload = value("""(?is)["']en_str["']\s*:\s*["']([^"']+)["']""")
        if (encoded == null && payload == null) return PlayerScriptResult(null, emptyList())
        return Js.run({ trace("rhino error in player script: ${it.javaClass.simpleName}: ${it.message}") }) { context, scope ->
            ScriptableObject.putProperty(scope, "__pageURL", pageUrl)
            ScriptableObject.putProperty(scope, "encodedStr", encoded ?: "")
            val configObject = context.newObject(scope)
            ScriptableObject.putProperty(configObject, "playerUrlBase64", config ?: "")
            ScriptableObject.putProperty(scope, "playerConfig", configObject)
            val dataObject = context.newObject(scope)
            ScriptableObject.putProperty(dataObject, "en_str", payload ?: "")
            ScriptableObject.putProperty(scope, "playerData", dataObject)
            val responseArray = context.newArray(scope, responses.size)
            responses.forEachIndexed { index, value -> responseArray.put(index, responseArray, value) }
            ScriptableObject.putProperty(scope, "__responses", responseArray)
            for ((name, decode) in listOf("atob" to true, "btoa" to false)) {
                ScriptableObject.putProperty(scope, name, object : org.mozilla.javascript.BaseFunction() {
                    override fun call(cx: Context, scope: Scriptable, thisObj: Scriptable, args: Array<out Any>): Any {
                        val text = Context.toString(args.firstOrNull() ?: "")
                        return if (decode) String(java.util.Base64.getDecoder().decode(text), Charsets.ISO_8859_1)
                            else java.util.Base64.getEncoder().encodeToString(text.toByteArray(Charsets.ISO_8859_1))
                    }
                })
            }
            context.evaluateString(scope, PLAYER_PRELUDE, "prelude", 1, null)
            // Rhino has generators and Promises, but no async-function syntax.
            // Replay the single native-fetched response synchronously. No live
            // network or concurrency is exposed to the page in either pass.
            val executable = if (payload != null) {
                context.evaluateString(scope, """
                    fetch = function(url) {
                        var i = __requests.length;
                        __requests.push(String(url));
                        if (i >= __responses.length) return {ok:false,status:0,json:function(){return {};}};
                        var value = JSON.parse(__responses[i]);
                        return {ok:true,status:200,json:function(){return value;}};
                    };
                """.trimIndent(), "native-replay", 1, null)
                synchronousReplayScript(playerScript)
            } else playerScript
            context.evaluateString(scope, executable, "player.js", 1, null)
            context.processMicrotasks()
            fun strings(name: String): List<String> {
                val values = ScriptableObject.getProperty(scope, name) as? org.mozilla.javascript.NativeArray
                    ?: return emptyList()
                return (0 until values.length.toInt()).map { Context.toString(values.get(it, values)) }
            }
            val container = ScriptableObject.getProperty(scope, "__container") as Scriptable
            val written = Context.toString(ScriptableObject.getProperty(container, "innerHTML"))
            val requests = strings("__requests")
            val url = if (requests.size > responses.size) null else
                strings("__frames").firstNotNullOfOrNull { makeUrl(it, page) }
                    ?: iframeUrls(written, page).firstOrNull()
            trace("rhino pjs.js wrote ${if (url != null) "iframe" else "no iframe"}")
            PlayerScriptResult(url?.toString(), requests)
        } ?: PlayerScriptResult(null, emptyList())
    }

    private fun generatedIframeUrl(html: String, playerScript: String, pageUrl: HttpUrl): HttpUrl? =
        playerScriptResult(html, playerScript, pageUrl.toString()).url?.toHttpUrlOrNull()

    /** Remove async/await code tokens for frozen-response replay, preserving
     * quoted payloads, template strings and comments verbatim. */
    private fun synchronousReplayScript(script: String): String {
        val output = StringBuilder()
        var i = 0
        while (i < script.length) {
            val start = i
            val ch = script[i]
            if (ch == '\'' || ch == '"' || ch == '`') {
                i++
                while (i < script.length) {
                    if (script[i] == '\\') { i = (i + 2).coerceAtMost(script.length); continue }
                    if (script[i++] == ch) break
                }
            } else if (script.startsWith("//", i)) {
                i = script.indexOf('\n', i).let { if (it < 0) script.length else it }
            } else if (script.startsWith("/*", i)) {
                i = script.indexOf("*/", i + 2).let { if (it < 0) script.length else it + 2 }
            } else if (ch.isLetter() || ch == '_' || ch == '$') {
                i++
                while (i < script.length && (script[i].isLetterOrDigit() || script[i] == '_' || script[i] == '$')) i++
                val token = script.substring(start, i)
                var next = i
                while (next < script.length && script[next].isWhitespace()) next++
                if ((token == "async" && script.startsWith("function", next)) ||
                    (token == "await" && i < script.length && script[i].isWhitespace())) continue
            } else i++
            output.append(script, start, i)
        }
        return output.toString()
    }

    private val PLAYER_PRELUDE = """
var window = this, self = this;
var __frames = [], __requests = [];
var __container = {
  innerHTML: '', textContent: '',
  appendChild: function(node) { if (node.src) __frames.push(node.src); },
  replaceChildren: function(node) { this.appendChild(node); }
};
var document = {
  location: {href: __pageURL}, referrer: '', cookie: '',
  getElementById: function() { return __container; },
  createElement: function() { return {style:{}, setAttribute:function(k,v) {this[k]=v;}}; },
  write: function() {}
};
var navigator = {userAgent:'iPhone',maxTouchPoints:0};
var console = {log:function(){},error:function(){},warn:function(){},info:function(){},debug:function(){},exception:function(){},trace:function(){}};
var setTimeout=function(){return 0},setInterval=setTimeout,clearTimeout=function(){},clearInterval=clearTimeout;
var TextEncoder=function(){};
TextEncoder.prototype.encode=function(text){var s=unescape(encodeURIComponent(text));return Uint8Array.from(s,function(c){return c.charCodeAt(0);});};
var TextDecoder=function(){};
TextDecoder.prototype.decode=function(bytes){var s='';for(var i=0;i<bytes.length;i++) s+=String.fromCharCode(bytes[i]);return decodeURIComponent(escape(s));};
var crypto={getRandomValues:function(bytes){for(var i=0;i<bytes.length;i++) bytes[i]=Math.floor(Math.random()*256);return bytes;}};
var URLSearchParams=function(values){this.values=values;};
URLSearchParams.prototype.toString=function(){var v=this.values;return Object.keys(v).map(function(k){return encodeURIComponent(k)+'='+encodeURIComponent(v[k]);}).join('&');};
var URL=function(value){var m=/^(https?):\/\/([^\/?#]+)([^#]*)(#.*)?$/i.exec(value);if(!m)throw Error('Invalid URL');this.hostname=m[2];this.username='';this.password='';this.hash=m[4]||'';if(m[2].indexOf('@')>=0)this.username='invalid';};
// Only record requests here. Native code validates and fetches the supported API.
// No AbortController: the page skips speculative media probes and selects its fallback URL.
var fetch=function(url){var i=__requests.length;__requests.push(String(url));if(i>=__responses.length)return new Promise(function(){});var data=JSON.parse(__responses[i]);return Promise.resolve({ok:true,status:200,json:function(){return Promise.resolve(data);}});};
    """.trimIndent()

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
        val isDataPlayer = html.regexContains("""["']en_str["']\s*:""")
        if (!html.contains("encodedStr") && !isDataPlayer) return null
        val scriptUrl = html.regexCaptures("""(?is)<script[^>]+src\s*=\s*["']([^"']+)["']""")
            .mapNotNull { it.getOrNull(1)?.let { raw -> makeUrl(raw, pageUrl) } }
            .firstOrNull { url -> url.pathSegments.last() == "pjs.js" ||
                (isDataPlayer && url.host == "im-imgs-bucket.oss-accelerate.aliyuncs.com" &&
                    url.pathSegments.last().endsWith(".js") && url.pathSegments.last().length > 20) }
            ?: return null
        val script = fetchPage(scriptUrl, pageUrl.toString()).first
        val responses = mutableListOf<String>()
        repeat(2) {
            currentCoroutineContext().ensureActive()
            val result = withContext(Dispatchers.Default) {
                playerScriptResult(html, script, pageUrl.toString(), responses)
            }
            result.url?.toHttpUrlOrNull()?.let { return it }
            val request = result.requests.firstOrNull()?.toHttpUrlOrNull() ?: return null
            if (responses.isNotEmpty() || request.scheme != "https" || request.host != "infozb6.video.qq.com" ||
                request.port != 443 || request.username.isNotEmpty() || request.password.isNotEmpty() ||
                request.encodedPath != "/cgi-bin/getliveinfo") return null
            responses.add(fetchPage(request, pageUrl.toString()).first)
        }
        return null
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
