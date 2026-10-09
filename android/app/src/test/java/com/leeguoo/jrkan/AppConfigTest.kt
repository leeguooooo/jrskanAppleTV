package com.leeguoo.jrkan

import com.leeguoo.jrkan.data.AppConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** Port of AppConfigTests in App/Tests/AppConfigTests.swift. */
class AppConfigTest {
    @Test
    fun decodesWorkerResponse() {
        val config = AppConfig.parse(
            """{"version":1,"watermark":{"enabled":true,"texts":["leeguoo.com","世界杯直播"],"motion":"drift","interval":45,"opacity":0.4,"hideForMembers":true},
               "slots":{"home_banner":{"enabled":true,"title":"欧冠决赛","detail":"今晚 3 点","url":"https://leeguoo.com/a","hideForMembers":true}}}""",
        )!!
        assertEquals(listOf("leeguoo.com", "世界杯直播"), config.watermark.texts)
        assertEquals(AppConfig.Motion.Drift, config.watermark.motion)
        assertEquals(45.0, config.watermark.interval, 0.0)
        assertEquals("https://leeguoo.com/a", config.slot("home_banner", isMember = false)?.link)
        assertNull(config.slot("home_banner", isMember = true))
        assertNull(config.visibleWatermark(isMember = true))
        assertNotNull(config.visibleWatermark(isMember = false))
    }

    @Test
    fun fallsBackFieldByField() {
        val config = AppConfig.parse(
            """{"watermark":{"texts":[],"motion":"spin","interval":1,"opacity":"x"},"slots":{"home_banner":{"enabled":true,"title":""},"later":{"enabled":true,"title":"新广告位","url":"http://plain"}},"future":42}""",
        )!!
        assertEquals(listOf("leeguoo.com"), config.watermark.texts)
        assertEquals(AppConfig.Motion.Drift, config.watermark.motion)
        assertEquals(5.0, config.watermark.interval, 0.0)
        assertEquals(0.55, config.watermark.opacity, 0.0)
        assertNull("no title, nothing to show", config.slot("home_banner", isMember = false))
        assertEquals("新广告位", config.slot("later", isMember = false)?.title)
        assertNull("only https links open", config.slot("later", isMember = false)?.link)
        assertEquals(AppConfig(), AppConfig.parse("{}"))
        assertNull(AppConfig.parse("not json"))
    }
}
