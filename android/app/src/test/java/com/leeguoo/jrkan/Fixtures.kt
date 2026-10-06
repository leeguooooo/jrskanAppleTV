package com.leeguoo.jrkan

import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import java.io.IOException

/** What a fixture answers: a body with a status, optionally as if redirected to [finalUrl]. */
data class FixtureReply(val body: String, val status: Int = 200, val finalUrl: String? = null)

/**
 * Port of the Swift URLProtocol stubs: an application interceptor that never
 * touches the network. Returning null fails the request like
 * `didFailWithError`; [FixtureReply.finalUrl] stands in for a redirect.
 */
fun fixtureClient(handler: (Request) -> FixtureReply?): OkHttpClient =
    OkHttpClient.Builder()
        .addInterceptor(Interceptor { chain ->
            val request = chain.request()
            val reply = handler(request) ?: throw IOException("fixture failure for ${request.url}")
            val finalRequest = reply.finalUrl?.let { request.newBuilder().url(it).build() } ?: request
            Response.Builder()
                .request(finalRequest)
                .protocol(Protocol.HTTP_1_1)
                .code(reply.status)
                .message("Fixture")
                .body(reply.body.toResponseBody("text/html".toMediaType()))
                .build()
        })
        .build()
