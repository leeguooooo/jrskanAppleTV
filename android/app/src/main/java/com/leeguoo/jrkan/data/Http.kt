package com.leeguoo.jrkan.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import okhttp3.CacheControl
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * The one error type of the data layer. [kind] tells the cases apart; the
 * message is the user-facing Chinese copy from the Swift error enums.
 *
 * Transport failures (DNS, timeouts, resets) are not wrapped: like URLError on
 * the Swift side they surface as [IOException].
 */
class JrsException(val kind: Kind) : Exception(kind.message) {
    enum class Kind(val message: String) {
        // ListingParserError
        NoMatches("公开页面当前没有可识别的比赛，或者页面格式已经变化。"),

        // JRSClientError
        InvalidResponse("目标站点返回了无效响应。"),
        MissingListingScript("没有在首页找到比赛列表数据。"),

        // SourcePageClientError
        NoChannels("这个入口没有找到可选择的具体频道。"),
        ChannelPageUnavailable("频道页面暂时无法访问。"),

        // StreamResolverError
        NoPlayableStream("这条线路暂未提供可播放的视频。"),
        StreamPageUnavailable("线路页面暂时无法访问。"),
        TooManyRedirects("线路嵌套层级异常，已停止继续解析。"),
        UnavailableStream("视频源暂不可用或尚未开播，请尝试其他线路。"),
    }
}

/** Shared HTTP plumbing; mirrors the URLRequest setup used by the Swift clients. */
object Http {
    const val USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
    const val HOMEPAGE = "https://www.jrs03.com/"

    /** No disk cache is configured, so every request goes to the network. */
    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .build()
    }

    /** Raw result of a GET: status, body bytes and the URL after redirects. */
    class Page(val status: Int, val body: ByteArray, val finalUrl: String) {
        /** `String(data:encoding:.utf8)`: null when the bytes are not valid UTF-8. */
        fun utf8(): String? = decodeUtf8Strict(body)

        /** UTF-8, else ISO-8859-1 (which never fails), as the Swift page fetchers do. */
        fun utf8OrLatin1(): String = utf8() ?: String(body, Charsets.ISO_8859_1)
    }

    /**
     * GET [url] on Dispatchers.IO with the site's User-Agent, an optional
     * Referer and caching disabled. Status codes are not checked here; each
     * caller enforces the range its Swift counterpart accepts.
     */
    suspend fun get(
        url: String,
        referer: String? = null,
        timeoutSeconds: Long = 20,
        client: OkHttpClient = this.client,
    ): Page = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url(url)
            .header("User-Agent", USER_AGENT)
            .apply { if (referer != null) header("Referer", referer) }
            .cacheControl(CacheControl.FORCE_NETWORK)
            .build()
        val call = client.newCall(request)
        call.timeout().timeout(timeoutSeconds, TimeUnit.SECONDS)
        call.await().use { response ->
            val bytes = response.body.bytes()
            Page(response.code, bytes, response.request.url.toString())
        }
    }

    fun decodeUtf8Strict(bytes: ByteArray): String? = try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
            .toString()
    } catch (_: CharacterCodingException) {
        null
    }

    private suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { cancel() }
        enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                continuation.resume(response) { _, value, _ -> value.close() }
            }
        })
    }
}

/** What to show for a failure: our own messages as-is, transport errors in plain Chinese. */
fun Throwable.userMessage(): String = when (this) {
    is JrsException -> message ?: "请求失败"
    is java.net.SocketTimeoutException -> "连接超时，请检查网络后重试。"
    is java.io.IOException -> "网络连接失败，请检查网络后重试。"
    else -> message ?: "请求失败"
}
