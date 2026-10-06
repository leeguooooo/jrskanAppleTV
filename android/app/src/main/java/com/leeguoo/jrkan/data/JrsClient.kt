package com.leeguoo.jrkan.data

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import kotlin.coroutines.cancellation.CancellationException

/** Port of JRSClient (App/Sources/Shared/JRSClient.swift). */
class JrsClient(
    val homepageUrl: String = Http.HOMEPAGE,
    private val client: OkHttpClient = Http.client,
) {
    data class Schedule(val matches: List<LiveMatch>, val eventUrl: String?)

    private val parser = JrsListingParser()

    suspend fun fetchMatches(): List<LiveMatch> {
        val schedule = fetchSchedule()
        val eventUrl = schedule.eventUrl ?: return schedule.matches
        return try {
            fetchEvents(eventUrl).applying(schedule.matches)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            currentCoroutineContext().ensureActive()
            schedule.matches
        }
    }

    suspend fun fetchSchedule(): Schedule {
        val homepage = fetchText(homepageUrl)
        val scriptUrl = listingScriptUrl(homepage)
            ?: throw JrsException(JrsException.Kind.MissingListingScript)
        val script = fetchText(scriptUrl)
        val matches = parser.parse(
            script = script,
            relativeTo = homepageUrl,
            playHosts = JrsListingParser.playHosts(homepage),
        )
        // index.js is only the initial list. The web page subsequently applies
        // the event snapshot configured by njs.js, including removing stale rows.
        return try {
            val configUrl = EventSnapshot.configUrl(homepage, homepageUrl)
                ?: return Schedule(matches, null)
            val config = fetchText(configUrl)
            val eventUrl = EventSnapshot.eventUrl(config, configUrl)
                ?: return Schedule(matches, null)
            Schedule(matches, eventUrl)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // A missing/broken event feed must not erase the schedule or invent
            // live/final status. The static list remains usable without badges.
            currentCoroutineContext().ensureActive()
            Schedule(matches, null)
        }
    }

    suspend fun fetchEvents(url: String): EventSnapshot = EventSnapshot.parse(fetchText(url))

    private fun listingScriptUrl(html: String): String? {
        val raw = html.regexCaptures("""(?is)<script[^>]+src="([^"]*index\.js[^"]*)"""")
            .firstOrNull()?.getOrNull(1) ?: return null
        return resolveUrl(raw, homepageUrl.toHttpUrlOrNull())?.toString()
    }

    private suspend fun fetchText(url: String): String {
        val page = Http.get(url, client = client)
        if (page.status !in 200 until 300) throw JrsException(JrsException.Kind.InvalidResponse)
        return page.utf8() ?: throw JrsException(JrsException.Kind.InvalidResponse)
    }
}

/**
 * Loads the second-level channel buttons exposed by a match source page.
 * The homepage only contains mirror entrances such as `直播①`; the actual
 * commentary choices (for example `中文高清 Q ⑤`) live on this page.
 */
class SourcePageClient(private val client: OkHttpClient = Http.client) {
    private val parser = SourcePageParser()

    suspend fun fetchChannels(sourcePageUrl: String): List<MatchSource> {
        val page = Http.get(sourcePageUrl, referer = Http.HOMEPAGE, client = client)
        if (page.status !in 200 until 400) throw JrsException(JrsException.Kind.ChannelPageUnavailable)
        val channels = parser.parse(page.utf8OrLatin1(), relativeTo = page.finalUrl)
        if (channels.isEmpty()) throw JrsException(JrsException.Kind.NoChannels)
        return channels
    }
}
