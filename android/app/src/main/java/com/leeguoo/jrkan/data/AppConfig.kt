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
) {
    data class Watermark(
        val enabled: Boolean = true,
        val texts: List<String> = listOf("leeguoo.com"),
        val motion: Motion = Motion.Hop,
        val interval: Double = 30.0,
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
                    "drift" -> Motion.Drift
                    "fixed" -> Motion.Fixed
                    else -> Motion.Hop
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
            return AppConfig(watermark, slots)
        }

        private fun JsonElement?.primitive() = this as? JsonPrimitive
        private fun JsonElement?.string() = primitive()?.takeIf { it.isString }?.content
        private fun JsonElement?.bool() = primitive()?.takeIf { !it.isString }?.booleanOrNull
        private fun JsonElement?.number() = primitive()?.takeIf { !it.isString }?.doubleOrNull
    }
}
