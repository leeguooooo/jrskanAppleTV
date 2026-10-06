package com.leeguoo.jrkan

import com.leeguoo.jrkan.data.JrsClient
import com.leeguoo.jrkan.data.MatchSchedule
import com.leeguoo.jrkan.data.MatchSource
import com.leeguoo.jrkan.data.SourcePageClient
import com.leeguoo.jrkan.data.StreamResolver
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

/**
 * Port of App/Tests/LiveSiteContractTests.swift. Hits the real website, so it
 * only runs with JRKAN_LIVE=1 in the environment or `-PjrkanLive=1` on the
 * Gradle command line (forwarded as the `jrkan.live` system property).
 */
class LiveSiteContractTest {
    @Before
    fun requireOptIn() {
        val flag = System.getenv("JRKAN_LIVE") ?: System.getProperty("jrkan.live")
        assumeTrue("Set JRKAN_LIVE=1 (or -PjrkanLive=1) to run the live-site contract.", flag == "1")
    }

    @Test
    fun websiteEventStatusContract() = runBlocking {
        val matches = JrsClient().fetchMatches()
        val supported = matches.filter {
            val ids = it.id.split(",")
            ids.size == 3 && (ids[1] == "1" || ids[1] == "2")
        }
        println("live: ${matches.size} matches, ${supported.size} football/basketball")
        assertFalse("Expected football/basketball fixtures from the website.", supported.isEmpty())
        assertTrue(
            "The event configuration, transport encoding or table schema changed; schedule-only fallback is active.",
            supported.all { it.providerState != null },
        )
        val now = System.currentTimeMillis()
        assertTrue(
            "The event feed contains an unsupported or stale match state.",
            supported.all { it.providerState?.status(now) != null },
        )
    }

    @Test
    fun currentPublicListingAndAtLeastOneHlsRoute() = runBlocking {
        val matches = JrsClient().fetchMatches()
        assertFalse(matches.isEmpty())
        val liveMatches = matches.filter { MatchSchedule.status(it).isLive }
        val candidates = (liveMatches.ifEmpty { matches }).flatMap { it.sources }.take(12)
        assertFalse(candidates.isEmpty())

        val resolver = StreamResolver()
        var lastError: Throwable? = null
        for (source in candidates) {
            try {
                val stream = resolver.resolve(source.pageUrl)
                println("live: ${source.name} ${source.pageUrl} -> $stream")
                assertTrue(stream.contains(".m3u8", ignoreCase = true))
                return@runBlocking
            } catch (e: Exception) {
                println("live: ${source.name} ${source.pageUrl} failed: ${e.message}")
                lastError = e
            }
        }
        throw AssertionError("No sampled route returned a valid HLS playlist: ${lastError?.message ?: "unknown error"}")
    }

    /**
     * Android-only: the second-level channels are where pjs.js/encodedStr and
     * index.min.js/decryptUrlWithExpiry live. Walk them until one stream
     * resolves through Rhino, and fail if Rhino could not run a script the
     * site served (the JavaScriptCore → Rhino swap is the risky part).
     */
    @Test
    fun resolvesAStreamThroughTheRhinoPath() = runBlocking {
        val matches = JrsClient().fetchMatches()
        val liveMatches = matches.filter { MatchSchedule.status(it).isLive }
        val entrances = (liveMatches + matches).distinct().flatMap { it.sources }.take(10)
        val channels = LinkedHashMap<String, MatchSource>()
        for (entrance in entrances) {
            try {
                SourcePageClient().fetchChannels(entrance.pageUrl).forEach { channels.putIfAbsent(it.pageUrl, it) }
            } catch (e: Exception) {
                println("rhino: channels of ${entrance.pageUrl} failed: ${e.message}")
            }
        }
        println("rhino: ${channels.size} channels from ${entrances.size} entrances")

        var rhinoPages = 0
        val engineFailures = ArrayList<String>()
        var resolvedViaRhino: String? = null
        var resolvedOther = 0
        for (channel in channels.values.take(40)) {
            val trace = ArrayList<String>()
            val resolver = StreamResolver(trace = { trace += it })
            val result = withTimeoutOrNull(60_000) {
                try {
                    resolver.resolve(channel.pageUrl)
                } catch (e: Exception) {
                    "error: ${e.message}"
                }
            } ?: "error: timeout"
            val fetched = trace.count { it.startsWith("rhino path:") }
            val evaluated = trace.count { it.startsWith("rhino pjs.js wrote") || it.startsWith("rhino decryptUrlWithExpiry") }
            if (fetched > 0) rhinoPages += 1
            if (fetched > evaluated) engineFailures += "${channel.name} ${channel.pageUrl}: ${trace.filter { it.startsWith("rhino") }}"
            println("rhino: [${channel.name}] ${channel.pageUrl} -> $result")
            trace.filter { it.startsWith("rhino") }.forEach { println("rhino:     $it") }
            if (!result.startsWith("error:")) {
                if (fetched > 0 && fetched == evaluated) {
                    resolvedViaRhino = result
                    break
                }
                resolvedOther += 1
            }
        }
        println("rhino: pages using JS=$rhinoPages, engine failures=${engineFailures.size}, resolved other=$resolvedOther, via rhino=$resolvedViaRhino")
        // Hard failure only for the engine itself; an offline stream behind a
        // script that ran fine is the site's state, not a porting bug.
        assertTrue("Rhino could not run site scripts:\n${engineFailures.joinToString("\n")}", engineFailures.isEmpty())
    }
}
