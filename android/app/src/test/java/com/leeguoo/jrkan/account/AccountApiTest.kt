package com.leeguoo.jrkan.account

import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AccountApiTest {
    private val clock = 1_000_000_000L
    private val stub = StubAccountServer()
    private val api = stub.api(now = { clock })

    @After
    fun tearDown() = stub.close()

    private suspend fun expectError(block: suspend () -> Unit): AccountError {
        try {
            block()
        } catch (e: AccountError) {
            return e
        }
        fail("expected an AccountError")
        throw AssertionError()
    }

    @Test
    fun exchangeCodeSendsPkceVerifierAndRedirect() = runTest {
        stub.enqueue("/token", tokenJson("a1", expiresIn = 900))
        val tokens = api.exchangeCode("the-code", Pkce("verifier-1"))
        assertEquals(AuthTokens("a1", "r-new", "id", clock + 900_000), tokens)
        val request = stub.requests("/token").single()
        assertEquals("POST", request.method)
        assertTrue(request.headers["Content-Type"]!!.startsWith("application/x-www-form-urlencoded"))
        assertEquals("application/json", request.headers["Accept"])
        assertEquals(
            mapOf(
                "grant_type" to "authorization_code",
                "code" to "the-code",
                "redirect_uri" to "com.leeguoo.jrskan.tv:/oauth/callback",
                "code_verifier" to "verifier-1",
                "client_id" to "leeguoo-jrkan-ios",
            ),
            request.form,
        )
        // Sorted keys, RFC 3986 unreserved characters only, like the Swift client.
        assertTrue(request.body.startsWith("client_id=leeguoo-jrkan-ios&code=the-code&code_verifier="))
        assertTrue(request.body.contains("redirect_uri=com.leeguoo.jrskan.tv%3A%2Foauth%2Fcallback"))
    }

    @Test
    fun missingExpiryDefaultsToTenMinutes() = runTest {
        stub.enqueue("/token", """{"access_token":"a1"}""")
        val tokens = api.exchangeCode("c", Pkce("v"))
        assertEquals("", tokens.refreshToken)
        assertEquals(clock + 600_000, tokens.expiresAt)
    }

    @Test
    fun refreshKeepsTheOldRefreshTokenWhenNoneIsReturned() = runTest {
        stub.enqueue("/token", tokenJson("a2", refresh = null))
        val tokens = api.refresh("r-old")
        assertEquals("a2", tokens.accessToken)
        assertEquals("r-old", tokens.refreshToken)
        val form = stub.requests("/token").single().form
        assertEquals("refresh_token", form["grant_type"])
        assertEquals("r-old", form["refresh_token"])
    }

    @Test
    fun refreshRotates() = runTest {
        stub.enqueue("/token", tokenJson("a2", refresh = "r-rotated"))
        assertEquals("r-rotated", api.refresh("r-old").refreshToken)
    }

    @Test
    fun userInfoSendsBearer() = runTest {
        stub.enqueue("/userinfo", USER_INFO_JSON)
        val profile = api.userInfo("a1")
        assertEquals(AccountProfile(sub = "u1", email = "fan@example.com", name = "球迷"), profile)
        assertEquals("Bearer a1", stub.requests("/userinfo").single().headers["Authorization"])
    }

    @Test
    fun revokeIgnoresFailures() = runTest {
        stub.enqueue("/revoke", "<html>oops</html>", status = 500)
        api.revoke("r1")
        val form = stub.requests("/revoke").single().form
        assertEquals(mapOf("token" to "r1", "token_type_hint" to "refresh_token", "client_id" to "leeguoo-jrkan-ios"), form)
    }

    // MARK: Entitlements

    @Test
    fun membershipReadsTrialSourceAndLapsedRows() = runTest {
        stub.enqueue(
            "/api/billing/entitlements",
            """{"active_entitlement_keys":["jrkan.premium"],"entitlements":[{"entitlement_key":"jrkan.premium","status":"granted","valid_to":1007776000,"source":"promo","trial":true}],"expired_entitlements":[]}""",
        )
        val trial = api.membership("a")
        assertEquals(true, trial.isTrial)
        assertEquals(1_007_776_000_000L, trial.validUntil)
        assertEquals(clock, trial.checkedAt)
        assertNull(trial.lapsedAt)
        assertEquals("Bearer a", stub.requests("/api/billing/entitlements").single().headers["Authorization"])
    }

    @Test
    fun membershipLapsed() = runTest {
        stub.enqueue(
            "/api/billing/entitlements",
            """{"active_entitlement_keys":[],"entitlements":[],"expired_entitlements":[{"entitlement_key":"jrkan.premium","source":"promo","valid_to":999000},{"entitlement_key":"other.app","valid_to":999999}]}""",
        )
        val lapsed = api.membership("a")
        assertFalse(lapsed.isActive(clock))
        assertEquals(999_000_000L, lapsed.lapsedAt)
        assertEquals(false, lapsed.isTrial)
        assertNull(lapsed.validUntil)
        assertEquals("会员已过期", lapsed.summary(clock))
    }

    @Test
    fun membershipTakesTheLatestRelevantGrantAndIgnoresOthers() = runTest {
        stub.enqueue(
            "/api/billing/entitlements",
            """{"active_entitlement_keys":["jrkan.premium","membership.all_apps","other"],"entitlements":[
              {"entitlement_key":"jrkan.premium","status":"granted","valid_to":2000,"trial":true},
              {"entitlement_key":"membership.all_apps","status":"granted","valid_to":3000},
              {"entitlement_key":"jrkan.premium","status":"revoked","valid_to":9000},
              {"entitlement_key":"other","status":"granted","valid_to":8000}]}""",
        )
        val membership = api.membership("a")
        assertEquals(3_000_000L, membership.validUntil)
        assertEquals(false, membership.isTrial)
        assertEquals(setOf("jrkan.premium", "membership.all_apps", "other"), membership.activeKeys)
    }

    @Test
    fun anOpenEndedGrantNeverLapses() = runTest {
        stub.enqueue(
            "/api/billing/entitlements",
            """{"active_entitlement_keys":["membership.all_apps"],"entitlements":[
              {"entitlement_key":"membership.all_apps","status":"granted"},
              {"entitlement_key":"jrkan.premium","status":"granted","valid_to":3000}]}""",
        )
        val membership = api.membership("a")
        assertNull(membership.validUntil)
        assertTrue(membership.isActive(Long.MAX_VALUE))
        assertEquals("会员 · 长期有效", membership.summary(clock))
    }

    // MARK: Error mapping

    @Test
    fun accountExists() = runTest {
        stub.enqueue("/token", """{"error":"account_exists","error_description":"x","email":"fan@example.com"}""", status = 409)
        assertEquals(AccountError.AccountExists("fan@example.com"), expectError { api.exchangeCode("c", Pkce("v")) })
    }

    @Test
    fun oauthErrorBody() = runTest {
        stub.enqueue("/token", """{"error":"invalid_grant","error_description":"Invalid refresh token"}""", status = 400)
        val error = expectError { api.refresh("r") }
        assertEquals(AccountError.OAuth("invalid_grant", "Invalid refresh token"), error)
        assertTrue(error.endsSession)
    }

    @Test
    fun h3ErrorShape() = runTest {
        stub.enqueue("/userinfo", """{"statusCode":503,"statusMessage":"down"}""", status = 503)
        assertEquals(AccountError.Http(503, "down"), expectError { api.userInfo("a") })
        stub.enqueue("/api/billing/entitlements", """{"message":"boom"}""", status = 500)
        assertEquals(AccountError.Http(500, "boom"), expectError { api.membership("a") })
    }

    @Test
    fun bare401EndsTheSession() = runTest {
        stub.enqueue("/userinfo", "Unauthorized", status = 401)
        val error = expectError { api.userInfo("a") }
        assertEquals(AccountError.Http(401, null), error)
        assertTrue(error.endsSession)
    }

    @Test
    fun htmlErrorPageIsInvalidResponse() = runTest {
        stub.enqueue("/token", "<html><body>Bad gateway</body></html>", status = 502)
        assertEquals(AccountError.InvalidResponse, expectError { api.exchangeCode("c", Pkce("v")) })
    }

    @Test
    fun htmlSuccessPageIsInvalidResponse() = runTest {
        stub.enqueue("/userinfo", "<html>captive portal</html>")
        assertEquals(AccountError.InvalidResponse, expectError { api.userInfo("a") })
        stub.enqueue("/token", """{"token_type":"Bearer"}""")
        assertEquals(AccountError.InvalidResponse, expectError { api.refresh("r") })
    }

    @Test
    fun unreachableServerIsNetworkError() = runTest {
        val url = stub.server.url("/")
        stub.close()
        val dead = AccountApi(issuer = url, now = { clock })
        val error = expectError { dead.userInfo("a") }
        assertTrue(error is AccountError.Network)
        assertEquals("连不上账号中心，请检查网络后重试。", error.message)
    }
}
