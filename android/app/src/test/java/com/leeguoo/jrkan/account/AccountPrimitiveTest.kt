package com.leeguoo.jrkan.account

import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class AccountPrimitiveTest {
    private val now = 1_000_000_000L
    private val day = 86_400_000L

    @Test
    fun pkceChallengeIsBase64UrlSha256OfVerifier() {
        // Cross-checked with Python urlsafe_b64encode(sha256(verifier)) without padding.
        val pkce = Pkce("dBjftJeZ4CVP-mJ92K1qUdx9hR1j6ZD3J7nM-tvqsiA")
        assertEquals("H0RovHRT5_KwoWVfSYAbboov_sw3NeQhXBpFuSLdx54", pkce.challenge)
        val fresh = Pkce()
        assertEquals(43, fresh.verifier.length)
        assertTrue(fresh.verifier.matches(Regex("[A-Za-z0-9_-]+")))
        assertTrue(fresh.verifier != Pkce().verifier)
    }

    @Test
    fun placeholderEmailIsNeverShown() {
        val apple = AccountProfile(sub = "s", email = "apple-1a2b@users.account.invalid")
        assertNull(apple.visibleEmail)
        assertEquals("leeguoo 账号", apple.displayName)
        assertEquals("a@b.com", AccountProfile(sub = "s", email = "a@b.com", name = "").displayName)
        assertEquals("球迷", AccountProfile(sub = "s", email = "a@b.com", name = "球迷").displayName)
    }

    @Test
    fun membershipNeedsAMembershipKeyAndAnOpenPeriod() {
        assertFalse(Membership(activeKeys = setOf("something.else")).isActive(now))
        assertTrue(Membership(activeKeys = setOf("jrkan.premium")).isActive(now))
        assertTrue(Membership(activeKeys = setOf("membership.all_apps"), validUntil = now + 1).isActive(now))
        assertFalse(Membership(activeKeys = setOf("membership.all_apps"), validUntil = now).isActive(now))
        assertEquals("未开通会员", Membership().summary(now))
        assertEquals("会员 · 长期有效", Membership(activeKeys = setOf("jrkan.premium")).summary(now))
    }

    @Test
    fun trialAndLapsedSummaries() {
        val trial = Membership(activeKeys = setOf("jrkan.premium"), validUntil = now + (day * 11.2).toLong(), isTrial = true)
        assertEquals("免费试用 · 剩余 12 天", trial.summary(now))
        assertEquals(12, trial.daysLeft(now))
        assertEquals("开通会员 · ¥1.99/月", trial.purchaseTitle(now))
        val paid = Membership(activeKeys = setOf("jrkan.premium"), validUntil = now + day * 20, isTrial = false)
        assertEquals("续费 1 个月 · ¥1.99", paid.purchaseTitle(now))
        val expected = SimpleDateFormat("yyyy/MM/dd", Locale.CHINA).format(Date(now + day * 20))
        assertEquals("会员 · 有效期至 $expected", paid.summary(now))
        assertEquals("会员已过期", Membership(lapsedAt = now - 60_000).summary(now))
        // A cached trial that ran out while offline also reads as lapsed.
        assertEquals("会员已过期", Membership(activeKeys = setOf("jrkan.premium"), validUntil = now, isTrial = true).summary(now))
        assertEquals(0, Membership(validUntil = now - day).daysLeft(now))
        assertEquals("开通会员 · ¥1.99/月", Membership().purchaseTitle(now))
    }

    @Test
    fun oldCachedMembershipStillDecodes() {
        val json = Json { ignoreUnknownKeys = true }
        val membership = json.decodeFromString(Membership.serializer(), """{"activeKeys":["jrkan.premium"],"checkedAt":1000}""")
        assertNull(membership.isTrial)
        assertNull(membership.lapsedAt)
        assertEquals(setOf("jrkan.premium"), membership.activeKeys)
    }

    @Test
    fun storedAccountRoundTrips() {
        val json = Json { ignoreUnknownKeys = true }
        val account = StoredAccount(
            tokens = AuthTokens("a", "r", null, 42),
            profile = AccountProfile(sub = "u1", name = "球迷"),
            membership = Membership(activeKeys = setOf("jrkan.premium"), validUntil = 99, isTrial = true),
        )
        assertEquals(account, json.decodeFromString(StoredAccount.serializer(), json.encodeToString(StoredAccount.serializer(), account)))
    }

    @Test
    fun tokensNeedRefreshAMinuteEarly() {
        val tokens = AuthTokens("a", "r", null, expiresAt = now + 60_000)
        assertTrue(tokens.needsRefresh(now))
        assertFalse(tokens.needsRefresh(now - 1))
    }

    @Test
    fun authorizeUrlCarriesPkceAndRedirect() {
        val pkce = Pkce("dBjftJeZ4CVP-mJ92K1qUdx9hR1j6ZD3J7nM-tvqsiA")
        val url = AccountApi().authorizeUrl(pkce, "s1").toHttpUrl()
        assertEquals("account.leeguoo.com", url.host)
        assertEquals("/authorize", url.encodedPath)
        assertEquals("code", url.queryParameter("response_type"))
        assertEquals("leeguoo-jrkan-ios", url.queryParameter("client_id"))
        assertEquals("com.leeguoo.jrskan.tv:/oauth/callback", url.queryParameter("redirect_uri"))
        assertEquals("openid profile email", url.queryParameter("scope"))
        assertEquals(pkce.challenge, url.queryParameter("code_challenge"))
        assertEquals("S256", url.queryParameter("code_challenge_method"))
        assertEquals("s1", url.queryParameter("state"))
    }

    @Test
    fun configUrls() {
        assertEquals("https://account.leeguoo.com/account", AccountConfig.manageUrl)
        assertEquals("https://account.leeguoo.com/membership/jrkan", AccountConfig.membershipUrl)
    }

    @Test
    fun errorsEndSessionOnlyForDeadRefreshTokens() {
        assertTrue(AccountError.OAuth("invalid_grant", null).endsSession)
        assertTrue(AccountError.Http(401, null).endsSession)
        assertFalse(AccountError.OAuth("access_denied", null).endsSession)
        assertFalse(AccountError.Http(500, null).endsSession)
        assertFalse(AccountError.Network("x").endsSession)
        assertFalse(AccountError.InvalidResponse.endsSession)
        assertFalse(AccountError.AccountExists(null).endsSession)
    }

    @Test
    fun errorMessages() {
        assertEquals("Invalid refresh token", AccountError.OAuth("invalid_grant", "Invalid refresh token").message)
        assertEquals("invalid_grant", AccountError.OAuth("invalid_grant", null).message)
        assertEquals("账号中心返回 503", AccountError.Http(503, null).message)
        assertEquals("down", AccountError.Http(503, "down").message)
        assertEquals("连不上账号中心，请检查网络后重试。", AccountError.Network("timeout").message)
        assertEquals("账号中心暂时不可用，请稍后再试。", AccountError.InvalidResponse.message)
        assertEquals(
            "这个 Apple ID 的邮箱已经注册过账号。请先用原来的方式登录，再到账号中心「登录方式」里绑定 Apple。",
            AccountError.AccountExists("x@y.com").message,
        )
    }

    @Test
    fun redirectParsing() {
        assertTrue(AccountSession.isCallback("com.leeguoo.jrskan.tv:/oauth/callback?code=c&state=s"))
        assertTrue(AccountSession.isCallback("com.leeguoo.jrskan.tv:///oauth/callback?code=c"))
        assertFalse(AccountSession.isCallback("https://account.leeguoo.com/oauth/callback?code=c"))
        assertFalse(AccountSession.isCallback("com.leeguoo.jrskan.tv:/other"))
        assertEquals(
            mapOf("code" to "a b", "state" to "s+1", "error_description" to "拒绝"),
            AccountSession.parseQuery("com.leeguoo.jrskan.tv:/oauth/callback?code=a%20b&state=s%2B1&error_description=%E6%8B%92%E7%BB%9D#frag"),
        )
    }
}
