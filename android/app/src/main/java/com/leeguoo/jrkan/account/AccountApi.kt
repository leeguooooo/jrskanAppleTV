package com.leeguoo.jrkan.account

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * Thin HTTP layer over the account center's OIDC endpoints. Stateless:
 * tokens are passed in and handed back. Port of AccountAPI.swift (the
 * Apple-native and device-code exchanges are not needed on Android).
 */
class AccountApi(
    private val client: OkHttpClient = defaultClient,
    val issuer: HttpUrl = AccountConfig.issuer,
    val clientId: String = AccountConfig.CLIENT_ID,
    private val now: () -> Long = System::currentTimeMillis,
) {
    // MARK: Browser sign-in

    fun authorizeUrl(pkce: Pkce, state: String): String =
        endpoint("authorize").newBuilder()
            .addQueryParameter("response_type", "code")
            .addQueryParameter("client_id", clientId)
            .addQueryParameter("redirect_uri", AccountConfig.REDIRECT_URI)
            .addQueryParameter("scope", AccountConfig.SCOPE)
            .addQueryParameter("state", state)
            .addQueryParameter("code_challenge", pkce.challenge)
            .addQueryParameter("code_challenge_method", "S256")
            .build()
            .toString()

    suspend fun exchangeCode(code: String, pkce: Pkce): AuthTokens = tokens(
        form(
            "token",
            mapOf(
                "grant_type" to "authorization_code",
                "code" to code,
                "redirect_uri" to AccountConfig.REDIRECT_URI,
                "code_verifier" to pkce.verifier,
                "client_id" to clientId,
            ),
        ),
    )

    // MARK: Session

    /** Refresh tokens rotate on every use; the old one is dead once this returns. */
    suspend fun refresh(refreshToken: String): AuthTokens {
        val tokens = tokens(
            form(
                "token",
                mapOf("grant_type" to "refresh_token", "refresh_token" to refreshToken, "client_id" to clientId),
            ),
        )
        return if (tokens.refreshToken.isEmpty()) tokens.copy(refreshToken = refreshToken) else tokens
    }

    /** RFC 7009 answers 200 for anything, so there is nothing to report. */
    suspend fun revoke(token: String) {
        try {
            send(form("revoke", mapOf("token" to token, "token_type_hint" to "refresh_token", "client_id" to clientId)))
        } catch (_: AccountError) {
        }
    }

    suspend fun userInfo(accessToken: String): AccountProfile =
        decode<AccountProfile>(send(bearer("userinfo", accessToken)))

    suspend fun membership(accessToken: String): Membership {
        val payload = decode<EntitlementsPayload>(send(bearer("api/billing/entitlements", accessToken)))
        val relevant = payload.entitlements.filter {
            it.status == "granted" && it.entitlementKey in AccountConfig.membershipKeys
        }
        val validUntil: Long? = if (relevant.any { it.validTo == null }) null
        else relevant.mapNotNull { it.validTo }.maxOrNull()?.let { it * 1000 }
        val lapsed = payload.expiredEntitlements.orEmpty()
            .filter { it.entitlementKey in AccountConfig.membershipKeys }
            .mapNotNull { it.validTo }
            .maxOrNull()
        return Membership(
            activeKeys = payload.activeEntitlementKeys.toSet(),
            validUntil = validUntil,
            checkedAt = now(),
            isTrial = relevant.isNotEmpty() && relevant.all { it.trial == true },
            lapsedAt = lapsed?.let { it * 1000 },
        )
    }

    // MARK: Plumbing

    @Serializable
    private class TokenPayload(
        @SerialName("access_token") val accessToken: String,
        @SerialName("refresh_token") val refreshToken: String? = null,
        @SerialName("id_token") val idToken: String? = null,
        @SerialName("expires_in") val expiresIn: Long? = null,
    )

    @Serializable
    private class EntitlementsPayload(
        @SerialName("active_entitlement_keys") val activeEntitlementKeys: List<String>,
        val entitlements: List<Row>,
        @SerialName("expired_entitlements") val expiredEntitlements: List<Lapsed>? = null,
    ) {
        @Serializable
        class Row(
            @SerialName("entitlement_key") val entitlementKey: String,
            val status: String,
            @SerialName("valid_to") val validTo: Long? = null,
            /** The free first-use trial (the server marks it, source stays "promo"). */
            val trial: Boolean? = null,
        )

        @Serializable
        class Lapsed(
            @SerialName("entitlement_key") val entitlementKey: String,
            @SerialName("valid_to") val validTo: Long? = null,
        )
    }

    @Serializable
    private class ErrorPayload(
        val error: String? = null,
        @SerialName("error_description") val errorDescription: String? = null,
        val email: String? = null,
        /** h3's createError shape. */
        val statusMessage: String? = null,
        val message: String? = null,
    )

    private suspend fun tokens(request: Request): AuthTokens {
        val payload = decode<TokenPayload>(send(request))
        return AuthTokens(
            accessToken = payload.accessToken,
            refreshToken = payload.refreshToken ?: "",
            idToken = payload.idToken,
            expiresAt = now() + (payload.expiresIn ?: 600) * 1000,
        )
    }

    /**
     * An HTML page (proxy, captive portal, an endpoint not deployed yet) is
     * not worth showing the viewer as a JSON decoding error.
     */
    private inline fun <reified T> decode(body: String): T =
        try {
            json.decodeFromString<T>(body)
        } catch (_: IllegalArgumentException) { // SerializationException is one
            throw AccountError.InvalidResponse
        }

    private fun endpoint(path: String): HttpUrl = issuer.newBuilder().addPathSegments(path).build()

    private fun bearer(path: String, accessToken: String): Request =
        Request.Builder().url(endpoint(path)).header("Authorization", "Bearer $accessToken").build()

    private fun form(path: String, fields: Map<String, String>): Request {
        val body = fields.entries.sortedBy { it.key }
            .joinToString("&") { "${it.key}=${percentEncode(it.value)}" }
        return Request.Builder()
            .url(endpoint(path))
            .post(body.toRequestBody(FORM))
            .build()
    }

    private suspend fun send(request: Request): String = withContext(Dispatchers.IO) {
        val call = client.newCall(request.newBuilder().header("Accept", "application/json").build())
        val (status, body) = try {
            call.execute().use { it.code to it.body.string() }
        } catch (e: IOException) {
            throw AccountError.Network(e.message ?: e.toString())
        }
        if (status !in 200..299) {
            val error = try {
                json.decodeFromString<ErrorPayload>(body)
            } catch (_: IllegalArgumentException) {
                null
            }
            if (error?.error == "account_exists") throw AccountError.AccountExists(error.email)
            error?.error?.let { throw AccountError.OAuth(it, error.errorDescription) }
            if (error == null) throw if (status == 401) AccountError.Http(401, null) else AccountError.InvalidResponse
            throw AccountError.Http(status, error.statusMessage ?: error.message)
        }
        body
    }

    companion object {
        private val FORM = "application/x-www-form-urlencoded".toMediaType()
        private val json = Json { ignoreUnknownKeys = true }

        val defaultClient: OkHttpClient by lazy {
            OkHttpClient.Builder().callTimeout(20, TimeUnit.SECONDS).build()
        }

        /** Unreserved characters (RFC 3986) stay; every other UTF-8 byte is %XX. */
        internal fun percentEncode(value: String): String = buildString {
            for (byte in value.toByteArray(Charsets.UTF_8)) {
                val c = byte.toInt() and 0xff
                val ch = c.toChar()
                if (ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' || ch == '-' || ch == '.' || ch == '_' || ch == '~') {
                    append(ch)
                } else {
                    append('%').append("0123456789ABCDEF"[c shr 4]).append("0123456789ABCDEF"[c and 0xf])
                }
            }
        }
    }
}
