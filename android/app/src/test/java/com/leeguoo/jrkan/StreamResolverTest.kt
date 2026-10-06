package com.leeguoo.jrkan

import com.leeguoo.jrkan.data.JrsException
import com.leeguoo.jrkan.data.SourcePageClient
import com.leeguoo.jrkan.data.StreamResolver
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Port of App/Tests/StreamResolverTests.swift (the data-layer cases). */
class StreamResolverTest {
    private val resolver = StreamResolver()

    /** ResolverFixtureProtocol from the Swift tests. */
    private val fixtures: OkHttpClient = fixtureClient { request ->
        when (request.url.encodedPath) {
            "/siblings.html" -> FixtureReply("""<iframe src="bad.html"></iframe><iframe src="good.html"></iframe>""")
            "/script-failure.html" -> FixtureReply(
                """<script>var encodedStr = 'x';</script><script src="pjs.js"></script><iframe src="good.html"></iframe>""",
            )
            "/cycle-parent.html" -> FixtureReply("""<iframe src="cycle.html"></iframe><iframe src="good.html"></iframe>""")
            "/cycle.html" -> FixtureReply("""<iframe src="cycle.html"></iframe>""")
            "/good.html" -> FixtureReply("""<source src="live.m3u8">""")
            "/multiple.html" -> FixtureReply("""<source src="expired.m3u8"><source src="live.m3u8">""")
            "/redirect.html" -> FixtureReply(
                """<source src="live.m3u8"><a class="ok" href="channel.html"><strong>Channel</strong></a>""",
                finalUrl = "https://fixture.example/landed/player.html",
            )
            "/bad.html", "/pjs.js", "/expired.m3u8" -> FixtureReply("Not found", status = 404)
            "/fake.m3u8" -> FixtureReply("<html>Offline</html>")
            "/empty.m3u8" -> FixtureReply("#EXTM3U\n")
            "/live.m3u8", "/landed/live.m3u8", "/slow.m3u8" -> FixtureReply("#EXTM3U\n#EXTINF:5,\nsegment.ts\n")
            else -> FixtureReply("Unknown fixture", status = 404)
        }
    }

    @Test
    fun extractsDirectHlsUrl() {
        val html = """
        <video>
          <source src="https://media.example/live/game.m3u8?token=abc&amp;expires=123">
        </video>
        """.trimIndent()
        assertEquals(
            "https://media.example/live/game.m3u8?token=abc&expires=123",
            resolver.extractM3U8Url(html, "http://play.example/350.html"),
        )
    }

    @Test
    fun extractsEscapedAndRelativeMediaUrls() {
        val page = "https://fixture.example/player/index.html"
        assertEquals(
            "https://media.example/live.m3u8?token=a&expires=2",
            resolver.extractM3U8Url("""var url = "https:\/\/media.example\/live.m3u8?token=a&expires=2";""", page),
        )
        assertEquals(
            "https://fixture.example/media/live.m3u8?token=a&expires=2",
            resolver.extractM3U8Url("""<source src="../media/live.m3u8?token=a&amp;expires=2">""", page),
        )
    }

    @Test
    fun hostAndIdPreserveAllNestedSignatureParameters() {
        val page = "https://fixture.example/player.html?id=/live.m3u8?expire=1&sign=a=b"
        assertEquals(
            "https://media.example/live.m3u8?expire=1&sign=a=b",
            resolver.extractM3U8Url("""let purl = "https://media.example" + id;""", page),
        )
    }

    @Test
    fun continuesAfterBrokenSiblingScriptAndMediaCandidates() = runTest {
        val resolver = StreamResolver(fixtures)
        for (path in listOf("siblings.html", "script-failure.html", "multiple.html", "cycle-parent.html")) {
            assertEquals(path, "https://fixture.example/live.m3u8", resolver.resolve("https://fixture.example/$path"))
        }
    }

    @Test
    fun usesFinalPageUrlForRelativeMediaAndChannelLinks() = runTest {
        val page = "https://fixture.example/redirect.html"
        assertEquals("https://fixture.example/landed/live.m3u8", StreamResolver(fixtures).resolve(page))
        val channels = SourcePageClient(fixtures).fetchChannels(page)
        assertEquals("https://fixture.example/landed/channel.html", channels.first().pageUrl)
    }

    @Test
    fun followsRealHttpRedirectsOverTheWire() = runTest {
        // The fixture interceptor fakes the final URL; this checks that OkHttp's
        // own redirect handling reports it the same way.
        val server = MockWebServer()
        try {
            server.enqueue(MockResponse().setResponseCode(302).addHeader("Location", "/landed/player.html"))
            server.enqueue(MockResponse().setBody("""<source src="live.m3u8">"""))
            server.enqueue(MockResponse().setBody("#EXTM3U\n#EXTINF:5,\nsegment.ts\n"))
            server.start()
            val stream = StreamResolver().resolve(server.url("/redirect.html").toString())
            assertEquals(server.url("/landed/live.m3u8").toString(), stream)
            val first = server.takeRequest()
            assertEquals("/redirect.html", first.path)
            assertEquals("https://www.jrs03.com/", first.getHeader("Referer"))
            assertEquals(true, first.getHeader("User-Agent")?.contains("Safari"))
        } finally {
            server.shutdown()
        }
    }

    @Test
    fun rejectsHttpErrorHtmlAndEmptyPlaylistsBeforePlayback() = runTest {
        for (path in listOf("expired.m3u8", "fake.m3u8", "empty.m3u8")) {
            try {
                StreamResolver(fixtures).resolve("https://fixture.example/$path")
                fail("Accepted unusable stream: $path")
            } catch (e: JrsException) {
                assertEquals(path, JrsException.Kind.UnavailableStream, e.kind)
                assertEquals("视频源暂不可用或尚未开播，请尝试其他线路。", e.message)
            }
        }
    }

    @Test
    fun stopsAtMaximumDepth() = runTest {
        val deep = fixtureClient { request ->
            val n = request.url.pathSegments.last().removeSuffix(".html").toInt()
            FixtureReply("""<iframe src="${n + 1}.html"></iframe>""")
        }
        try {
            StreamResolver(deep, maximumDepth = 3).resolve("https://fixture.example/0.html")
            fail("expected TooManyRedirects")
        } catch (e: JrsException) {
            assertEquals(JrsException.Kind.TooManyRedirects, e.kind)
        }
    }

    @Test
    fun buildsHlsUrlFromPlayerHostAndId() {
        assertEquals(
            "https://hdl.example.com/live/123.m3u8?auth_key=abc",
            resolver.extractM3U8Url(
                """var purl = "//hdl.example.com"+id;""",
                "https://player.example/msss.html?id=/live/123.m3u8?auth_key=abc",
            ),
        )
    }

    @Test
    fun resolvesProtocolRelativeAndRelativeIframes() {
        val html = """
        <iframe src="//cloud.example/player.html"></iframe>
        <iframe src="/play/350.html"></iframe>
        <script>
        element.innerHTML = "<iframe src='/play/"+id1+".html'></iframe>";
        </script>
        """.trimIndent()
        assertEquals(
            listOf("https://cloud.example/player.html", "http://play.example/play/350.html"),
            resolver.iframeUrls(html, "http://play.example/play/sm.html?id=350&id2="),
        )
    }

    @Test
    fun buildsPlayerPathFromIdWhenNoStaticIframeExists() {
        val html = """element.innerHTML = "<iframe src='/play/"+id1+".html'></iframe>";"""
        assertEquals(
            listOf("http://play.example/play/351.html"),
            resolver.iframeUrls(html, "http://play.example/play/sm.html?id=351&id2="),
        )
    }

    @Test
    fun doesNotTreatPlayerWrapperQueryAsHlsMedia() {
        val html = """<iframe src="//cloud.example/msss.html?id=/live/123.m3u8?token=abc"></iframe>"""
        assertNull(resolver.extractM3U8Url(html, "http://play.example/350.html"))
    }

    private val reversedHostPlayer = """
    function restoreStreamUrl(value) {
      const domainParts = value.split(".");
      domainParts[domainParts.length - 2] = domainParts[domainParts.length - 2]
        .split("").reverse().join("");
    }
    const id = J_get("id");
    const purl = restoreStreamUrl(id);
    """.trimIndent()

    @Test
    fun restoresPlayerHostAndPreservesCompleteSignedQuery() {
        assertEquals(
            "https://cdn.example.com:8443/live/game.m3u8?auth_key=a=b&token=xyz&device=4",
            resolver.extractM3U8Url(
                reversedHostPlayer,
                "https://player.example/msss.html?id=//cdn.elpmaxe.com:8443/live/game.m3u8?auth_key=a=b&token=xyz&device=4",
            ),
        )
    }

    @Test
    fun restoresPercentEncodedPlayerId() {
        assertEquals(
            "https://cdn.example.com/live/game.m3u8?token=a%2Bb&expires=123",
            resolver.extractM3U8Url(
                reversedHostPlayer,
                "https://player.example/msss.html?id=https%3A%2F%2Fcdn.elpmaxe.com%2Flive%2Fgame.m3u8%3Ftoken%3Da%252Bb%26expires%3D123",
            ),
        )
    }

    @Test
    fun doesNotRestoreHostWithoutPlayerTransformation() {
        assertNull(resolver.extractM3U8Url("const purl = id;", "https://player.example/msss.html?id=//cdn.elpmaxe.com/live/game.m3u8"))
    }

    @Test
    fun extractsIframeGeneratedByEncryptedPlayerScript() {
        val playerScript = """
        document.getElementById("myElement").innerHTML =
          "<iframe src='https://cloud.example/player/paps.html?id=" + encodedStr + "'></iframe>";
        """.trimIndent()
        assertEquals(
            "https://cloud.example/player/paps.html?id=encrypted-payload",
            resolver.generatedIframeUrl(
                """var encodedStr = "encrypted-payload";""",
                playerScript,
                "http://play.example/play/kbs/?id=5",
            ),
        )
    }

    @Test
    fun evaluatesEncryptedPlayerPageToHlsUrl() {
        val pageScript = """
        var encryptedBase64Str = "payload";
        function decryptUrlWithExpiry(value) {
          return CryptoLibraryLoaded && value === "payload"
            ? "https://media.example/live/chinese-hd.m3u8?token=abc"
            : "";
        }
        """.trimIndent()
        assertEquals(
            "https://media.example/live/chinese-hd.m3u8?token=abc",
            resolver.evaluateEncryptedHlsUrl(
                "var CryptoLibraryLoaded = true;",
                pageScript,
                "https://cloud.example/player/paps.html?id=payload",
            ),
        )
    }

    // Rhino-specific behaviour that JavaScriptCore gave for free.

    @Test
    fun scriptErrorsAndRunawayScriptsYieldNull() {
        val html = """var encodedStr = "x";"""
        assertNull(resolver.generatedIframeUrl(html, "throw new Error('boom');", "http://play.example/"))
        assertNull(resolver.generatedIframeUrl(html, "undefinedFunction();", "http://play.example/"))
        assertNull(resolver.evaluateEncryptedHlsUrl("", "var encryptedBase64Str = 1;", "http://play.example/"))
        // Page scripts must not reach Java through LiveConnect.
        assertNull(
            resolver.evaluateEncryptedHlsUrl(
                "",
                "var encryptedBase64Str = 1; function decryptUrlWithExpiry() { return java.lang.System.getProperty('user.home') + '/x.m3u8'; }",
                "http://play.example/",
            ),
        )
    }

    @Test
    fun survivesAntiDebugRecursionTrap() {
        // The shape of the jsjiami.com v6 guard on cloud.sdsxlw.com/paps.html:
        // unbounded recursion that only ends when the engine's stack overflows
        // and the surrounding try/catch swallows the error.
        val pageScript = """
        var encryptedBase64Str = "p";
        function trap(counter) {
          if (("" + counter / counter).length !== 1 || counter % 20 === 0) { (function(){}).constructor("debugger")(); }
          trap(++counter);
        }
        try { trap(0); } catch (e) {}
        function decryptUrlWithExpiry(v) { return "https://media.example/live/" + v + ".m3u8"; }
        """.trimIndent()
        val started = System.currentTimeMillis()
        assertEquals(
            "https://media.example/live/p.m3u8",
            resolver.evaluateEncryptedHlsUrl("", pageScript, "http://play.example/"),
        )
        assertTrue(System.currentTimeMillis() - started < 5_000)
    }

    @Test
    fun runsModernScriptSyntaxInInterpretedMode() {
        // CryptoJS-style library plus ES6 syntax the live player pages use.
        val library = """
        (function (root, factory) { root.Lib = factory(); }(this, function () {
          const pad = (s) => `${'$'}{s}`;
          let parts = ["https://media.example", "live", "es6.m3u8"];
          return { join: () => parts.map(pad).join("/") };
        }));
        """.trimIndent()
        val pageScript = """
        var encryptedBase64Str = "p";
        function decryptUrlWithExpiry(v) { return window.Lib.join() + "?k=" + v + "&t=" + document.location.href.length; }
        """.trimIndent()
        assertEquals(
            "https://media.example/live/es6.m3u8?k=p&t=20",
            resolver.evaluateEncryptedHlsUrl(library, pageScript, "http://play.example/"),
        )
    }
}
