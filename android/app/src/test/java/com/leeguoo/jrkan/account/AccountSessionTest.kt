package com.leeguoo.jrkan.account

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runTest
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.CountDownLatch

class AccountSessionTest {
    private var clock = 1_000_000_000L
    private val stub = StubAccountServer()

    @After
    fun tearDown() = stub.close()

    private fun api() = stub.api(now = { clock })

    private fun signedInStore(expiresAt: Long) =
        MemoryAccountStore(StoredAccount(tokens = AuthTokens("a-old", "r-old", null, expiresAt)))

    private fun session(store: AccountStore) = AccountSession(api = api(), store = store, now = { clock })

    @Test
    fun codeExchangeLoadsAccount() = runTest {
        stub.enqueue("/token", tokenJson("a1"))
        stub.enqueue("/userinfo", USER_INFO_JSON)
        stub.enqueue("/api/billing/entitlements", MEMBER_JSON)
        val store = MemoryAccountStore()
        val session = session(store)

        session.run { session.api.exchangeCode("code", Pkce("v")) }

        assertTrue(session.isSignedIn)
        assertEquals("球迷", session.profile?.displayName)
        assertTrue(session.isMember)
        assertEquals("r-new", store.stored?.tokens?.refreshToken)
        assertEquals("球迷", store.stored?.profile?.name)
        assertNull(session.lastError.value)
        assertFalse(session.isSigningIn.value)
        assertFalse(session.isRefreshing.value)
        assertEquals("Bearer a1", stub.requests("/userinfo").single().headers["Authorization"])
    }

    @Test
    fun accountExistsIsExplainedNotSignedIn() = runTest {
        stub.enqueue("/token", """{"error":"account_exists","error_description":"x","email":"fan@example.com"}""", status = 409)
        val session = session(MemoryAccountStore())
        session.run { session.api.exchangeCode("code", Pkce("v")) }
        assertFalse(session.isSignedIn)
        assertEquals(AccountError.AccountExists(null).message, session.lastError.value)
        assertFalse(session.isSigningIn.value)
    }

    @Test
    fun concurrentCallersShareOneRefresh() = runTest {
        val gate = CountDownLatch(1)
        stub.enqueue("/token", tokenJson("a-fresh", refresh = "r-rotated"), gate = gate)
        val store = signedInStore(expiresAt = clock + 30_000)
        val session = session(store)

        val callers = List(5) { async { session.validAccessToken() } }
        // Let every caller reach the shared refresh before it answers.
        testScheduler.runCurrent()
        Thread.sleep(200)
        gate.countDown()
        val tokens = callers.awaitAll()

        assertEquals(List(5) { "a-fresh" }, tokens)
        val refreshes = stub.requests("/token")
        assertEquals(1, refreshes.size)
        assertEquals("r-old", refreshes[0].form["refresh_token"])
        assertEquals("refresh_token", refreshes[0].form["grant_type"])
        assertEquals("r-rotated", store.stored?.tokens?.refreshToken)
        assertEquals("r-rotated", session.account.value?.tokens?.refreshToken)
        // The rotated token is fresh now: no second refresh.
        assertEquals("a-fresh", session.validAccessToken())
        assertEquals(1, stub.requests("/token").size)
    }

    @Test
    fun laterRefreshUsesTheRotatedToken() = runTest {
        stub.enqueue("/token", tokenJson("a-1", refresh = "r-1", expiresIn = 600))
        stub.enqueue("/token", tokenJson("a-2", refresh = "r-2", expiresIn = 600))
        val store = signedInStore(expiresAt = clock)
        val session = session(store)
        assertEquals("a-1", session.validAccessToken())
        clock += 600_000
        assertEquals("a-2", session.validAccessToken())
        assertEquals(listOf("r-old", "r-1"), stub.requests("/token").map { it.form["refresh_token"] })
        assertEquals("r-2", store.stored?.tokens?.refreshToken)
    }

    @Test
    fun freshTokenIsUsedWithoutRefreshing() = runTest {
        val session = session(signedInStore(expiresAt = clock + 600_000))
        assertEquals("a-old", session.validAccessToken())
        assertTrue(stub.requests("/token").isEmpty())
    }

    @Test
    fun signedOutCallerGets401() = runTest {
        val session = session(MemoryAccountStore())
        try {
            session.validAccessToken()
            fail()
        } catch (e: AccountError) {
            assertEquals(AccountError.Http(401, null), e)
        }
    }

    @Test
    fun revokedRefreshTokenSignsOut() = runTest {
        stub.enqueue("/token", """{"error":"invalid_grant","error_description":"Invalid refresh token"}""", status = 400)
        val store = signedInStore(expiresAt = clock)
        val session = session(store)
        session.refreshAccount()
        assertFalse(session.isSignedIn)
        assertNull(store.stored)
        assertEquals("登录已过期，请重新登录。", session.lastError.value)
        assertFalse(session.isRefreshing.value)
    }

    @Test
    fun unauthorizedUserInfoSignsOut() = runTest {
        stub.enqueue("/userinfo", "nope", status = 401)
        stub.enqueue("/api/billing/entitlements", MEMBER_JSON)
        val store = signedInStore(expiresAt = clock + 600_000)
        val session = session(store)
        session.refreshAccount()
        assertFalse(session.isSignedIn)
        assertEquals(AccountSession.SESSION_EXPIRED, session.lastError.value)
    }

    @Test
    fun signedOutWhileRefreshingDoesNotRestoreTheAccount() = runTest {
        val gate = CountDownLatch(1)
        stub.enqueue("/token", tokenJson("a-fresh", refresh = "r-rotated"), gate = gate)
        stub.enqueue("/revoke", "{}")
        val store = signedInStore(expiresAt = clock)
        val session = session(store)

        val caller = async {
            try {
                session.validAccessToken()
                null
            } catch (e: AccountError) {
                e
            }
        }
        testScheduler.runCurrent()
        Thread.sleep(200)
        session.signOut()
        gate.countDown()

        assertEquals(AccountError.Http(401, null), caller.await())
        assertFalse(session.isSignedIn)
        assertNull(store.stored)
        // Signing out is not an expiry: no message.
        assertNull(session.lastError.value)
    }

    @Test
    fun offlineKeepsCachedMembership() = runTest {
        val cached = StoredAccount(
            tokens = AuthTokens("a", "r", null, clock + 600_000),
            profile = AccountProfile(sub = "u1", name = "球迷"),
            membership = Membership(activeKeys = setOf("jrkan.premium")),
        )
        stub.enqueue("/userinfo", """{"statusMessage":"down"}""", status = 503)
        stub.enqueue("/api/billing/entitlements", MEMBER_JSON)
        val session = session(MemoryAccountStore(cached))
        session.refreshAccount()
        assertTrue(session.isSignedIn)
        assertTrue(session.isMember)
        assertNull(session.lastError.value)
    }

    @Test
    fun refreshIfStaleSkipsARecentCheck() = runTest {
        val cached = StoredAccount(
            tokens = AuthTokens("a", "r", null, clock + 600_000),
            profile = AccountProfile(sub = "u1", name = "球迷"),
            membership = Membership(checkedAt = clock - 60_000),
        )
        stub.enqueue("/userinfo", USER_INFO_JSON)
        stub.enqueue("/api/billing/entitlements", MEMBER_JSON)
        val session = session(MemoryAccountStore(cached))
        session.refreshIfStale()
        assertTrue(stub.requests("/userinfo").isEmpty())
        session.refreshIfStale(maxAgeMillis = 30_000)
        assertEquals(1, stub.requests("/userinfo").size)
        assertTrue(session.isMember)
        assertEquals(clock, session.membership.checkedAt)
    }

    @Test
    fun signOutClearsLocallyAndRevokesRefreshToken() = runTest {
        stub.enqueue("/revoke", "{}")
        val store = signedInStore(expiresAt = clock + 600_000)
        val session = session(store)
        session.signOut()
        assertFalse(session.isSignedIn)
        assertNull(store.stored)
        val revoke = stub.requests("/revoke")
        assertEquals(1, revoke.size)
        assertEquals("r-old", revoke[0].form["token"])
    }

    @Test
    fun offlineMockNeverTouchesTheStoreOrNetwork() = runTest {
        val session = AccountSession.mock("trial", now = clock)
        assertTrue(session.isSignedIn)
        assertEquals("免费试用 · 剩余 77 天", session.membership.summary(clock))
        session.refreshAccount()
        assertEquals("测试用户", session.profile?.displayName)
        assertFalse(AccountSession.mock("expired", now = clock).isMember)
        assertEquals("会员已过期", AccountSession.mock("expired", now = clock).membership.summary(clock))
    }

    // MARK: Browser sign-in

    @Test
    fun browserSignInRoundTrip() = runTest {
        stub.enqueue("/token", tokenJson("a1"))
        stub.enqueue("/userinfo", USER_INFO_JSON)
        stub.enqueue("/api/billing/entitlements", MEMBER_JSON)
        val store = MemoryAccountStore()
        val session = session(store)

        val url = session.beginBrowserSignIn().toHttpUrl()
        val state = url.queryParameter("state")!!
        val pending = store.pending!!
        assertEquals(state, pending.state)
        assertEquals(Pkce(pending.verifier).challenge, url.queryParameter("code_challenge"))

        assertTrue(session.handleRedirect("com.leeguoo.jrskan.tv:/oauth/callback?code=the-code&state=$state"))

        val form = stub.requests("/token").single().form
        assertEquals("the-code", form["code"])
        assertEquals(pending.verifier, form["code_verifier"])
        assertTrue(session.isSignedIn)
        assertTrue(session.isMember)
        assertNull(store.pending)
    }

    @Test
    fun pendingSignInSurvivesProcessDeath() = runTest {
        stub.enqueue("/token", tokenJson("a1"))
        stub.enqueue("/userinfo", USER_INFO_JSON)
        stub.enqueue("/api/billing/entitlements", MEMBER_JSON)
        val store = MemoryAccountStore()
        val state = session(store).beginBrowserSignIn().toHttpUrl().queryParameter("state")!!
        val verifier = store.pending!!.verifier

        val revived = session(store)
        assertTrue(revived.handleRedirect("com.leeguoo.jrskan.tv:/oauth/callback?state=$state&code=c2"))
        assertEquals(verifier, stub.requests("/token").single().form["code_verifier"])
        assertTrue(revived.isSignedIn)
    }

    @Test
    fun mismatchedStateIsRejected() = runTest {
        val store = MemoryAccountStore()
        val session = session(store)
        session.beginBrowserSignIn()
        assertTrue(session.handleRedirect("com.leeguoo.jrskan.tv:/oauth/callback?code=c&state=forged"))
        assertEquals("登录回调校验失败，请重试。", session.lastError.value)
        assertTrue(stub.requests("/token").isEmpty())
        assertFalse(session.isSignedIn)
        // The real sign-in can still finish.
        assertNotNull(store.pending)
    }

    @Test
    fun redirectWithoutPendingSignInIsRejected() = runTest {
        val session = session(MemoryAccountStore())
        assertTrue(session.handleRedirect("com.leeguoo.jrskan.tv:/oauth/callback?code=c&state=s"))
        assertEquals("登录回调校验失败，请重试。", session.lastError.value)
    }

    @Test
    fun deniedInTheBrowserShowsTheReason() = runTest {
        val store = MemoryAccountStore()
        val session = session(store)
        val state = session.beginBrowserSignIn().toHttpUrl().queryParameter("state")!!
        session.handleRedirect("com.leeguoo.jrskan.tv:/oauth/callback?error=access_denied&error_description=%E5%B7%B2%E5%8F%96%E6%B6%88&state=$state")
        assertEquals("已取消", session.lastError.value)
        assertFalse(session.isSignedIn)
        assertNull(store.pending)
        assertTrue(stub.requests("/token").isEmpty())
    }

    @Test
    fun otherLinksAreNotHandled() = runTest {
        val session = session(MemoryAccountStore())
        assertFalse(session.handleRedirect("https://www.jrs03.com/play/1"))
        assertNull(session.lastError.value)
    }
}
