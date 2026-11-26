package com.leeguoo.jrkan.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException

/**
 * Port of WeiboClient.swift: Weibo as an anonymous visitor, from the device.
 *
 * weibo.com (profile feeds, statuses/show) and weibo.cn (m.weibo.cn search)
 * each want their own visitor identity, minted from their own passport host.
 * A 403, "ok":-100 or the visitor-system HTML page mints it again and retries
 * once.
 */
class WeiboClient(base: OkHttpClient = Http.client) {
    enum class Site(val visitorEndpoint: String, val probe: String) {
        Com("https://passport.weibo.com/visitor/genvisitor2", "https://weibo.com/"),
        Cn("https://visitor.passport.weibo.cn/visitor/genvisitor2", "https://m.weibo.cn/"),
    }

    class Blocked : IOException("微博暂时拒绝了请求，稍后再试。")

    /** In memory only, and separate from every other request the app makes. */
    private val jar = object : CookieJar {
        private val cookies = mutableListOf<Cookie>()

        @Synchronized
        override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
            val now = System.currentTimeMillis()
            for (cookie in cookies) {
                this.cookies.removeAll { it.name == cookie.name && it.domain == cookie.domain && it.path == cookie.path }
                if (cookie.expiresAt > now) this.cookies += cookie
            }
        }

        @Synchronized
        override fun loadForRequest(url: HttpUrl): List<Cookie> {
            val now = System.currentTimeMillis()
            return cookies.filter { it.expiresAt > now && it.matches(url) }
        }
    }

    private val client = base.newBuilder().cookieJar(jar).build()

    /** One page of an uploader's video feed (weibo.com profile "视频" tab). */
    suspend fun uploaderVideos(uid: String, cursor: String? = null): JsonObject {
        val url = "https://weibo.com/ajax/profile/getWaterFallContent".toHttpUrl().newBuilder()
            .addQueryParameter("uid", uid)
            .apply { if (cursor != null) addQueryParameter("cursor", cursor) }
            .build()
        return json(url, Site.Com, "https://weibo.com/u/$uid")
    }

    /** Video search on m.weibo.cn (the desktop search needs a login). */
    suspend fun searchVideos(query: String): JsonObject {
        val url = "https://m.weibo.cn/api/container/getIndex".toHttpUrl().newBuilder()
            .addQueryParameter("containerid", "100103type=64&q=$query")
            .addQueryParameter("page_type", "searchall")
            .build()
        return json(url, Site.Cn, "https://m.weibo.cn/search")
    }

    /** One post with freshly signed play links. */
    suspend fun status(id: String): JsonObject {
        val url = "https://weibo.com/ajax/statuses/show".toHttpUrl().newBuilder().addQueryParameter("id", id).build()
        return json(url, Site.Com, "https://weibo.com/")
    }

    private suspend fun json(url: HttpUrl, site: Site, referer: String): JsonObject = withContext(Dispatchers.IO) {
        repeat(2) { attempt ->
            if (attempt > 0 || !hasVisitor(site)) mintVisitor(site)
            val request = Request.Builder().url(url)
                .header("User-Agent", USER_AGENT)
                .header("Referer", referer)
                .header("Accept", "application/json, text/plain, */*")
                .header("X-Requested-With", "XMLHttpRequest")
                .build()
            val (status, body) = client.newCall(request).execute().use { it.code to it.body.string() }
            val root = runCatching { Json.parseToJsonElement(body) as? JsonObject }.getOrNull()
            if (status != 200 || root == null) {
                if (status == 200 || status == 403 || status == 432) return@repeat
                throw IOException("微博返回了 $status")
            }
            if ((root["ok"] as? JsonPrimitive)?.intOrNull == -100) return@repeat
            if (root["error"] != null && root["data"] == null && root["mblogid"] == null) return@repeat
            return@withContext root
        }
        throw Blocked()
    }

    private fun hasVisitor(site: Site): Boolean =
        jar.loadForRequest(site.probe.toHttpUrl()).any { it.name == "SUB" && it.value.isNotEmpty() && it.value != "deleted" }

    /** Weibo's own visitor page does this POST; the answer sets SUB/SUBP. */
    private fun mintVisitor(site: Site) {
        val body = FormBody.Builder()
            .add("cb", "visitor_gray_callback").add("tid", "").add("from", "weibo").add("webdriver", "false")
            .build()
        val request = Request.Builder().url(site.visitorEndpoint).header("User-Agent", USER_AGENT).post(body).build()
        val ok = client.newCall(request).execute().use { it.code == 200 }
        if (!ok || !hasVisitor(site)) throw Blocked()
    }

    companion object {
        private const val USER_AGENT = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    }
}
