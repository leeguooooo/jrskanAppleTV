package com.leeguoo.jrkan.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.math.BigDecimal
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

/**
 * Port of EventSnapshot (App/Sources/Shared/JRSClient.swift): the live status
 * feed the website applies on top of the static index.js listing.
 */
data class EventSnapshot(
    val events: Map<String, Event>,
    /** Epoch milliseconds. */
    val updatedAt: Long,
) {
    data class Event(
        /** Epoch milliseconds. */
        val kickoff: Long,
        val state: ProviderMatchState,
    )

    fun applying(matches: List<LiveMatch>): List<LiveMatch> = matches.mapNotNull { match ->
        val ids = match.id.split(",")
        if (ids.size != 3 || (ids[1] != "1" && ids[1] != "2")) return@mapNotNull match
        // An absent football/basketball row is removed by the web page too;
        // absence means "no longer listed", not proof the match finished.
        val event = events["${ids[1]},${ids[2]}"] ?: return@mapNotNull null
        match.copy(
            time = timeFormatter.format(Instant.ofEpochMilli(event.kickoff)),
            providerState = event.state,
        )
    }

    companion object {
        private val timeFormatter: DateTimeFormatter =
            DateTimeFormatter.ofPattern("MM-dd HH:mm", Locale.US).withZone(MatchSchedule.feedZone)

        fun configUrl(html: String, baseUrl: String): String? {
            val raw = html.regexCaptures("""(?i)((?:https?:)?//[^\s"'<>]+/tmp/njs\.js)""")
                .firstOrNull()?.getOrNull(1) ?: return null
            return resolveUrl(raw, baseUrl.toHttpUrlOrNull())?.toString()
        }

        fun eventUrl(config: String, baseUrl: String): String? {
            val raw = config.regexCaptures("""["']base_zqlq_url["']\s*:\s*["']([^"']+)["']""")
                .firstOrNull()?.getOrNull(1) ?: return null
            val url = resolveUrl(raw, baseUrl.toHttpUrlOrNull()) ?: return null
            return url.newBuilder()
                .removeAllQueryParameters("callback")
                .addQueryParameter("callback", "jrkanEvents")
                .build()
                .toString()
        }

        fun parse(response: String, nowMillis: Long = System.currentTimeMillis()): EventSnapshot {
            fun invalid(): Nothing = throw JrsException(JrsException.Kind.InvalidResponse)

            val text = response.trim()
            val json = text.regexCaptures("""(?s)^[A-Za-z_$][\w$]*\s*\((.*)\)\s*;?$""")
                .firstOrNull()?.getOrNull(1) ?: text
            var element = parseJson(json) ?: invalid()
            val envelope = (element as? JsonArray)?.map { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
            val ciphertext = envelope?.takeIf { it.size == 2 && it.all { s -> s != null } }
                ?.let { decodeBase64Strict(it[0]!!) }
            if (ciphertext != null) {
                // The website's public transport encoding (page.live-2.1-min.js).
                // Decode data only; never execute the returned JavaScript.
                val plaintext = try {
                    val cipher = Cipher.getInstance("AES/ECB/PKCS5Padding")
                    cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec("abcdabcdabcdabcd".toByteArray(), "AES"))
                    cipher.doFinal(ciphertext)
                } catch (_: Exception) {
                    invalid()
                }
                element = parseJson(Http.decodeUtf8Strict(plaintext) ?: invalid()) ?: invalid()
            }

            val payload = element as? JsonObject ?: invalid()
            if (payload["success"].asBool() != true) invalid()
            val timestamp = payload["time"].asDouble() ?: invalid()
            val table = payload["list"] as? JsonObject ?: invalid()
            val fields = (table["fields"] as? JsonArray)?.map { it.asString() ?: invalid() } ?: invalid()
            val rows = (table["values"] as? JsonArray)?.map { it as? JsonArray ?: invalid() } ?: invalid()
            if (!fields.containsAll(listOf("id", "sportid", "status", "st_first", "st_second"))) invalid()
            if (fields.toSet().size != fields.size) invalid()

            val updatedAtSeconds = timestamp
            val nowSeconds = nowMillis / 1000.0
            if (!(nowSeconds - updatedAtSeconds < 10 * 60 && updatedAtSeconds - nowSeconds < 5 * 60)) invalid()
            val updatedAt = (updatedAtSeconds * 1000).toLong()

            val events = LinkedHashMap<String, Event>()
            for (row in rows) {
                if (row.size != fields.size) invalid()
                val values = fields.zip(row).toMap()
                val id = values["id"].asLong() ?: invalid()
                val sport = values["sportid"].asInt() ?: invalid()
                val code = values["status"].asInt() ?: invalid()
                val kickoff = values["st_first"].asDouble() ?: invalid()
                val period = values["st_second"].asDouble() ?: invalid()
                events["$sport,$id"] = Event(
                    kickoff = kickoff.toLong(),
                    state = ProviderMatchState(
                        sportId = sport,
                        code = code,
                        periodStartedAt = period.toLong(),
                        updatedAt = updatedAt,
                        matchType = values["mtype"].asInt() ?: 0,
                        homeScore = values["s1"].asInt(),
                        awayScore = values["s2"].asInt(),
                        homeHalfScore = values["hs1"].asInt(),
                        awayHalfScore = values["hs2"].asInt(),
                        homeCorners = values["corner1"].asInt(),
                        awayCorners = values["corner2"].asInt(),
                    ),
                )
            }
            return EventSnapshot(events, updatedAt)
        }

        private fun parseJson(text: String): JsonElement? = try {
            Json.parseToJsonElement(text)
        } catch (_: Exception) {
            null
        }

        // Mirrors of Swift's `as?` casts on JSONSerialization values.

        private fun JsonElement?.number(): BigDecimal? {
            val primitive = this as? JsonPrimitive ?: return null
            if (primitive is JsonNull || primitive.isString) return null
            return primitive.content.toBigDecimalOrNull()
        }

        /** `as? Double`: any JSON number. */
        private fun JsonElement?.asDouble(): Double? = number()?.toDouble()

        /** `as? Int`: only numbers with an exact integer value (1.0 yes, 1.5 no). */
        private fun JsonElement?.asLong(): Long? = try {
            number()?.longValueExact()
        } catch (_: ArithmeticException) {
            null
        }

        private fun JsonElement?.asInt(): Int? = try {
            number()?.intValueExact()
        } catch (_: ArithmeticException) {
            null
        }

        /** `as? Bool`: JSON booleans, and the NSNumbers 0/1 that bridge to Bool. */
        private fun JsonElement?.asBool(): Boolean? {
            val primitive = this as? JsonPrimitive ?: return null
            if (primitive is JsonNull || primitive.isString) return null
            return when (primitive.content) {
                "true" -> true
                "false" -> false
                else -> when (number()?.compareTo(BigDecimal.ONE)) {
                    0 -> true
                    else -> if (number()?.signum() == 0) false else null
                }
            }
        }

        private fun JsonElement.asString(): String? =
            (this as? JsonPrimitive)?.takeIf { it.isString }?.content
    }
}
