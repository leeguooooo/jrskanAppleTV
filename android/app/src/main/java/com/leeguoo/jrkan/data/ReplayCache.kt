package com.leeguoo.jrkan.data

import android.content.Context
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import java.security.MessageDigest

/**
 * Small on-disk cache for 回看 (ReplayCache.swift), in the app's cache dir:
 * the list, a match's search, signed play links and ESPN look-ups are not
 * fetched again while still good. Lifetimes:
 * - uploader feeds: 10 minutes, then shown while refreshing;
 * - a match's search: 15 minutes for 6 hours after kickoff, 2 hours for two
 *   days, then a day; nothing found: 10 minutes;
 * - play links: until 10 minutes before Weibo's own Expires;
 * - ESPN fixture: found 30 days, not found 6 hours.
 */
object ReplayCache {
    var directory: File? = null
    private val json = Json { ignoreUnknownKeys = true }

    @Serializable
    private class Entry(val savedAt: Long, val value: String)

    fun init(context: Context) {
        directory = File(context.cacheDir, "replay").apply { mkdirs() }
        Thread { prune() }.start()
    }

    data class Hit<T>(val value: T, val savedAt: Long)

    fun <T> read(key: String, serializer: KSerializer<T>): Hit<T>? {
        val file = file(key) ?: return null
        return runCatching {
            val entry = json.decodeFromString(Entry.serializer(), file.readText())
            Hit(json.decodeFromString(serializer, entry.value), entry.savedAt)
        }.getOrNull()
    }

    fun <T> write(key: String, value: T, serializer: KSerializer<T>, now: Long = System.currentTimeMillis()) {
        val file = file(key) ?: return
        runCatching {
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(json.encodeToString(Entry.serializer(), Entry(now, json.encodeToString(serializer, value))))
            tmp.renameTo(file)
        }
    }

    fun prune(now: Long = System.currentTimeMillis()) {
        directory?.listFiles()?.forEach { if (now - it.lastModified() > 30 * 86_400_000L) it.delete() }
    }

    private fun file(key: String): File? {
        val dir = directory ?: return null
        val digest = MessageDigest.getInstance("SHA-256").digest(key.toByteArray()).joinToString("") { "%02x".format(it) }
        return File(dir, "$digest.json")
    }

    // Lifetimes

    const val LIBRARY_LIFETIME = 10 * 60_000L
    val videoList = ListSerializer(ReplayVideo.serializer())

    fun searchLifetime(kickoff: Long, foundAny: Boolean, now: Long = System.currentTimeMillis()): Long {
        if (!foundAny) return 10 * 60_000L
        val since = now - kickoff
        return when {
            since < 6 * 3_600_000L -> 15 * 60_000L
            since < 48 * 3_600_000L -> 2 * 3_600_000L
            else -> 24 * 3_600_000L
        }
    }

    fun searchKey(home: String, away: String, kickoff: Long) =
        "search:${ReplayVideo.Matchup(home, away).key}@${ReplayParsing.beijingDay(kickoff)}"

    /** A play link worth using: at least ten minutes left before it expires. */
    fun usableStreams(id: String, now: Long = System.currentTimeMillis()): List<ReplayStream>? {
        val hit = read("streams:$id", ListSerializer(ReplayStream.serializer())) ?: return null
        val expires = hit.value.firstOrNull()?.expiresAt ?: return null
        return if (expires - now > 10 * 60_000L) hit.value else null
    }

    fun storeStreams(streams: List<ReplayStream>, id: String) {
        if (streams.isNotEmpty()) write("streams:$id", streams, ListSerializer(ReplayStream.serializer()))
    }
}
