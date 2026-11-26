package com.leeguoo.jrkan.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull

/**
 * Watermark and ad slots, edited in Cloudflare (AppConfig.swift; KV key
 * `jrkan` behind config.leeguoo.com). Every field falls back on its own, so a
 * half-filled or newer config still works.
 */
data class AppConfig(
    val watermark: Watermark = Watermark(),
    val slots: Map<String, Slot> = emptyMap(),
    val replay: Replay = Replay(),
) {
    /** 回看 (AppConfig.Replay in AppConfig.swift). The defaults work with no remote config. */
    data class Replay(
        val enabled: Boolean = true,
        val uploaders: List<String> = listOf("7551290258", "2358578625"),
        val searchSuffix: String = " 回放",
        val minDuration: Double = 600.0,
        val fullDuration: Double = 5400.0,
        val windowHours: Double = 48.0,
    ) {
        val rules: ReplayRules get() = ReplayRules(minDuration, fullDuration, windowHours)
    }

    data class Watermark(
        val enabled: Boolean = true,
        val texts: List<String> = listOf("leeguoo.com"),
        val motion: Motion = Motion.Drift,
        val interval: Double = 8.0,
        val opacity: Double = 0.55,
        val hideForMembers: Boolean = false,
    )

    enum class Motion { Hop, Drift, Fixed }

    data class Slot(
        val enabled: Boolean = false,
        val title: String = "",
        val detail: String = "",
        val url: String = "",
        val hideForMembers: Boolean = true,
    ) {
        val link: String? get() = url.takeIf { it.startsWith("https://") }
    }

    fun visibleWatermark(isMember: Boolean): Watermark? =
        watermark.takeIf { it.enabled && !(it.hideForMembers && isMember) }

    fun slot(id: String, isMember: Boolean): Slot? =
        slots[id]?.takeIf { it.enabled && it.title.isNotEmpty() && !(it.hideForMembers && isMember) }

    companion object {
        /** null when the text is not a JSON object at all. */
        fun parse(text: String): AppConfig? {
            val root = runCatching { Json.parseToJsonElement(text) as? JsonObject }.getOrNull() ?: return null
            val base = Watermark()
            val w = root["watermark"] as? JsonObject ?: JsonObject(emptyMap())
            val texts = (w["texts"] as? JsonArray)?.mapNotNull { it.string()?.takeIf(String::isNotEmpty) }.orEmpty()
            val watermark = Watermark(
                enabled = w["enabled"].bool() ?: base.enabled,
                texts = texts.ifEmpty { base.texts },
                motion = when (w["motion"].string()) {
                    "hop" -> Motion.Hop
                    "fixed" -> Motion.Fixed
                    else -> Motion.Drift
                },
                interval = (w["interval"].number() ?: base.interval).coerceIn(5.0, 600.0),
                opacity = (w["opacity"].number() ?: base.opacity).coerceIn(0.1, 1.0),
                hideForMembers = w["hideForMembers"].bool() ?: base.hideForMembers,
            )
            val slots = (root["slots"] as? JsonObject).orEmpty().mapNotNull { (id, value) ->
                val s = value as? JsonObject ?: return@mapNotNull null
                id to Slot(
                    enabled = s["enabled"].bool() ?: false,
                    title = s["title"].string().orEmpty(),
                    detail = s["detail"].string().orEmpty(),
                    url = s["url"].string().orEmpty(),
                    hideForMembers = s["hideForMembers"].bool() ?: true,
                )
            }.toMap()
            val r = root["replay"] as? JsonObject ?: JsonObject(emptyMap())
            val baseReplay = Replay()
            val uploaders = (r["uploaders"] as? JsonArray)
                ?.mapNotNull { (it as? JsonPrimitive)?.content?.takeIf { s -> s.isNotEmpty() && s.all(Char::isDigit) } }
                .orEmpty().take(10)
            val replay = Replay(
                enabled = r["enabled"].bool() ?: baseReplay.enabled,
                uploaders = uploaders.ifEmpty { baseReplay.uploaders },
                searchSuffix = r["searchSuffix"].string() ?: baseReplay.searchSuffix,
                minDuration = (r["minDuration"].number() ?: baseReplay.minDuration).coerceIn(60.0, 3600.0),
                fullDuration = (r["fullDuration"].number() ?: baseReplay.fullDuration).coerceIn(1800.0, 14_400.0),
                windowHours = (r["windowHours"].number() ?: baseReplay.windowHours).coerceIn(6.0, 240.0),
            )
            return AppConfig(watermark, slots, replay)
        }

        private fun JsonElement?.primitive() = this as? JsonPrimitive
        private fun JsonElement?.string() = primitive()?.takeIf { it.isString }?.content
        private fun JsonElement?.bool() = primitive()?.takeIf { !it.isString }?.booleanOrNull
        private fun JsonElement?.number() = primitive()?.takeIf { !it.isString }?.doubleOrNull
    }
}
