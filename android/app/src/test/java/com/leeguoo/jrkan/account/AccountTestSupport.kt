package com.leeguoo.jrkan.account

import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import java.net.URLDecoder
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** A request as the stub saw it; the body is read eagerly. */
class Recorded(val path: String, val method: String, val headers: Map<String, String>, val body: String) {
    /** Form-encoded body as a map. */
    val form: Map<String, String>
        get() = body.split('&').filter { it.contains('=') }.associate {
            URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('='), "UTF-8")
        }
}

/**
 * Answers account-center requests from a per-test script, keyed by path.
 * The last reply for a path repeats. Port of StubAccountServer in AccountTests.swift.
 */
class StubAccountServer : AutoCloseable {
    private class Reply(val status: Int, val body: String, val gate: CountDownLatch?)

    private val replies = mutableMapOf<String, ArrayDeque<Reply>>()
    private val log = CopyOnWriteArrayList<Recorded>()
    val server = MockWebServer()

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.requestUrl?.encodedPath ?: ""
                log += Recorded(
                    path = path,
                    method = request.method ?: "",
                    headers = request.headers.associate { it.first to it.second },
                    body = request.body.readUtf8(),
                )
                val reply = synchronized(replies) {
                    val queue = replies[path]
                    when {
                        queue.isNullOrEmpty() -> Reply(404, """{"statusMessage":"no stub"}""", null)
                        queue.size == 1 -> queue.first()
                        else -> queue.removeFirst()
                    }
                }
                reply.gate?.await(10, TimeUnit.SECONDS)
                return MockResponse().setResponseCode(reply.status)
                    .setHeader("Content-Type", "application/json")
                    .setBody(reply.body)
            }
        }
        server.start()
    }

    /** [gate] holds the reply until it is counted down, to stage races. */
    fun enqueue(path: String, body: String, status: Int = 200, gate: CountDownLatch? = null) {
        synchronized(replies) { replies.getOrPut(path) { ArrayDeque() }.addLast(Reply(status, body, gate)) }
    }

    fun requests(path: String): List<Recorded> = log.filter { it.path == path }

    fun api(clientId: String = "leeguoo-jrkan-ios", now: () -> Long = { 0L }): AccountApi =
        AccountApi(client = OkHttpClient(), issuer = server.url("/"), clientId = clientId, now = now)

    override fun close() {
        server.shutdown()
    }
}

fun tokenJson(access: String, refresh: String? = "r-new", expiresIn: Int = 600): String {
    val refreshField = refresh?.let { ""","refresh_token":"$it"""" } ?: ""
    return """{"token_type":"Bearer","access_token":"$access"$refreshField,"id_token":"id","expires_in":$expiresIn}"""
}

const val USER_INFO_JSON = """{"sub":"u1","email":"fan@example.com","name":"球迷"}"""
const val MEMBER_JSON =
    """{"tenant_id":"tenant-jrkan","user_id":"u1","as_of":1,"active_entitlement_keys":["membership.all_apps"],"entitlements":[{"entitlement_key":"membership.all_apps","status":"granted","valid_to":4102444800}]}"""
