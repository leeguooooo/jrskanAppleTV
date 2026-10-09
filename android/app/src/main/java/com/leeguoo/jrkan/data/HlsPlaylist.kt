package com.leeguoo.jrkan.data

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.util.Locale

/**
 * The parts of an HLS playlist a recorder needs (HLSPlaylist.swift). A master
 * playlist only fills [variants] and [hasSeparateAudio]; a media playlist
 * fills the rest.
 */
data class HlsPlaylist(
    val variants: List<Variant> = emptyList(),
    /** `EXT-X-MEDIA` audio with its own URI: out of scope for recording. */
    val hasSeparateAudio: Boolean = false,
    val targetDuration: Double = 0.0,
    val mediaSequence: Int = 0,
    val segments: List<Segment> = emptyList(),
    val isEnded: Boolean = false,
) {
    data class Variant(val url: String, val bandwidth: Long)

    data class Key(val method: Method, val url: String?, val iv: ByteArray?) {
        sealed interface Method {
            data object Aes128 : Method
            data class Unsupported(val name: String) : Method
        }

        override fun equals(other: Any?): Boolean =
            other is Key && method == other.method && url == other.url && iv.contentEquals(other.iv)

        override fun hashCode(): Int = (method.hashCode() * 31 + url.hashCode()) * 31 + (iv?.contentHashCode() ?: 0)
    }

    data class Segment(
        val sequence: Int,
        val url: String,
        val duration: Double,
        val key: Key?,
        val mapUrl: String?,
        val discontinuity: Boolean,
    )

    val isMaster: Boolean get() = variants.isNotEmpty()

    val bestVariant: Variant? get() = variants.maxByOrNull { it.bandwidth }

    companion object {
        fun parse(text: String, baseUrl: String): HlsPlaylist {
            val base = baseUrl.toHttpUrlOrNull()
            fun resolve(value: String): String? = (base?.resolve(value) ?: value.toHttpUrlOrNull())?.toString()

            val variants = mutableListOf<Variant>()
            val segments = mutableListOf<Segment>()
            var hasSeparateAudio = false
            var targetDuration = 0.0
            var mediaSequence = 0
            var ended = false
            var key: Key? = null
            var mapUrl: String? = null
            var pendingDuration: Double? = null
            var pendingBandwidth: Long? = null
            var pendingDiscontinuity = false
            var sequence: Int? = null

            for (raw in text.lines()) {
                val line = raw.trim()
                if (line.isEmpty()) continue
                if (line.startsWith("#")) {
                    val colon = line.indexOf(':')
                    val tag = if (colon < 0) line else line.substring(0, colon)
                    val value = if (colon < 0) "" else line.substring(colon + 1)
                    when (tag) {
                        "#EXT-X-STREAM-INF" -> pendingBandwidth = attributes(value)["BANDWIDTH"]?.toLongOrNull() ?: 0
                        "#EXT-X-MEDIA" -> {
                            val attrs = attributes(value)
                            if (attrs["TYPE"] == "AUDIO" && attrs["URI"] != null) hasSeparateAudio = true
                        }
                        "#EXT-X-TARGETDURATION" -> targetDuration = value.toDoubleOrNull() ?: 0.0
                        "#EXT-X-MEDIA-SEQUENCE" -> mediaSequence = value.toIntOrNull() ?: 0
                        "#EXTINF" -> pendingDuration = value.substringBefore(',').toDoubleOrNull() ?: 0.0
                        "#EXT-X-DISCONTINUITY" -> pendingDiscontinuity = true
                        "#EXT-X-ENDLIST" -> ended = true
                        "#EXT-X-KEY" -> {
                            val attrs = attributes(value)
                            key = when (val method = attrs["METHOD"]?.uppercase(Locale.ROOT)) {
                                null, "NONE" -> null
                                else -> Key(
                                    if (method == "AES-128") Key.Method.Aes128 else Key.Method.Unsupported(method),
                                    attrs["URI"]?.let(::resolve),
                                    attrs["IV"]?.let(::hexBytes),
                                )
                            }
                        }
                        "#EXT-X-MAP" -> mapUrl = attributes(value)["URI"]?.let(::resolve)
                    }
                    continue
                }

                val url = resolve(line) ?: continue
                val bandwidth = pendingBandwidth
                val duration = pendingDuration
                if (bandwidth != null) {
                    variants += Variant(url, bandwidth)
                    pendingBandwidth = null
                } else if (duration != null) {
                    val number = sequence ?: mediaSequence
                    segments += Segment(number, url, duration, key, mapUrl, pendingDiscontinuity)
                    sequence = number + 1
                    pendingDuration = null
                    pendingDiscontinuity = false
                }
            }
            return HlsPlaylist(variants, hasSeparateAudio, targetDuration, mediaSequence, segments, ended)
        }

        /** `KEY=value,KEY="quoted, value"` → map, quotes removed. */
        fun attributes(text: String): Map<String, String> {
            val result = mutableMapOf<String, String>()
            val key = StringBuilder()
            val value = StringBuilder()
            var readingKey = true
            var quoted = false
            fun flush() {
                val name = key.toString().trim()
                if (name.isNotEmpty()) result[name] = value.toString()
                key.clear(); value.clear(); readingKey = true
            }
            for (c in text) {
                when {
                    readingKey -> if (c == '=') readingKey = false else if (c != ',') key.append(c)
                    c == '"' -> quoted = !quoted
                    c == ',' && !quoted -> flush()
                    else -> value.append(c)
                }
            }
            if (key.isNotEmpty()) flush()
            return result
        }

        private fun hexBytes(text: String): ByteArray? {
            val hex = if (text.lowercase(Locale.ROOT).startsWith("0x")) text.substring(2) else text
            if (hex.length % 2 != 0) return null
            return ByteArray(hex.length / 2) { i ->
                hex.substring(i * 2, i * 2 + 2).toIntOrNull(16)?.toByte() ?: return null
            }
        }

        fun path(url: String): String = url.toHttpUrlOrNull()?.encodedPath ?: url.substringBefore('?')
    }
}

/** One line of a recording's segment log, in recording order. */
sealed interface RecordedEntry {
    data class Map(val file: String) : RecordedEntry
    data class Segment(val file: String, val duration: Double, val discontinuity: Boolean) : RecordedEntry
}

/** The playlist a recording is played from; segments are stored decrypted. */
object RecordingPlaylist {
    fun render(entries: List<RecordedEntry>, ended: Boolean): String {
        val longest = entries.filterIsInstance<RecordedEntry.Segment>().maxOfOrNull { it.duration } ?: 0.0
        val usesMap = entries.any { it is RecordedEntry.Map }
        val lines = mutableListOf(
            "#EXTM3U",
            "#EXT-X-VERSION:${if (usesMap) 6 else 3}",
            "#EXT-X-TARGETDURATION:${maxOf(1, kotlin.math.ceil(longest).toInt())}",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:${if (ended) "VOD" else "EVENT"}",
        )
        var first = true
        for (entry in entries) {
            when (entry) {
                is RecordedEntry.Map -> lines += "#EXT-X-MAP:URI=\"${entry.file}\""
                is RecordedEntry.Segment -> {
                    if (entry.discontinuity && !first) lines += "#EXT-X-DISCONTINUITY"
                    lines += "#EXTINF:${format(entry.duration)},"
                    lines += entry.file
                    first = false
                }
            }
        }
        if (ended) lines += "#EXT-X-ENDLIST"
        return lines.joinToString("\n") + "\n"
    }

    fun logLine(entry: RecordedEntry): String = when (entry) {
        is RecordedEntry.Map -> "M\t${entry.file}\n"
        is RecordedEntry.Segment -> "S\t${entry.file}\t${format(entry.duration)}\t${if (entry.discontinuity) 1 else 0}\n"
    }

    fun parseLog(text: String): List<RecordedEntry> = text.split('\n').mapNotNull { line ->
        val fields = line.split('\t')
        when {
            fields[0] == "M" && fields.size >= 2 -> RecordedEntry.Map(fields[1])
            fields[0] == "S" && fields.size >= 4 ->
                fields[2].toDoubleOrNull()?.let { RecordedEntry.Segment(fields[1], it, fields[3] == "1") }
            else -> null
        }
    }

    private fun format(value: Double) = String.format(Locale.ROOT, "%.3f", value)
}
