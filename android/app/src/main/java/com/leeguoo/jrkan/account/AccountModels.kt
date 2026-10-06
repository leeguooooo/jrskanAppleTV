package com.leeguoo.jrkan.account

import kotlinx.serialization.Serializable
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.max

private const val DAY_MILLIS = 86_400_000L

@Serializable
data class AuthTokens(
    val accessToken: String,
    val refreshToken: String,
    val idToken: String? = null,
    /** Epoch millis. */
    val expiresAt: Long,
) {
    /** A minute of slack so a token never expires between check and use. */
    fun needsRefresh(now: Long): Boolean = now >= expiresAt - 60_000
}

@Serializable
data class AccountProfile(
    val sub: String,
    val email: String? = null,
    val name: String? = null,
    val picture: String? = null,
) {
    /**
     * Apple and WeChat sign-ups that shared no email get a placeholder
     * address on this domain; it means nothing to the viewer.
     */
    val visibleEmail: String?
        get() = email?.takeUnless { it.endsWith("@users.account.invalid") }

    val displayName: String
        get() = name?.takeIf { it.isNotEmpty() } ?: visibleEmail ?: "leeguoo 账号"
}

@Serializable
data class Membership(
    val activeKeys: Set<String> = emptySet(),
    /** Epoch millis; null with active keys means it never lapses. */
    val validUntil: Long? = null,
    val checkedAt: Long? = null,
    /** Only the free first-use trial is behind the active membership. */
    val isTrial: Boolean? = null,
    /** When the last membership ran out (epoch millis), if it did. */
    val lapsedAt: Long? = null,
) {
    fun isActive(now: Long = System.currentTimeMillis()): Boolean {
        if (activeKeys.none { it in AccountConfig.membershipKeys }) return false
        return validUntil?.let { it > now } ?: true
    }

    /** One line for the account screens, e.g. "免费试用 · 剩余 12 天". */
    fun summary(now: Long = System.currentTimeMillis()): String {
        if (!isActive(now)) return if (hasLapsed(now)) "会员已过期" else "未开通会员"
        val until = validUntil ?: return "会员 · 长期有效"
        if (isTrial == true) return "免费试用 · 剩余 ${daysLeft(now)} 天"
        return "会员 · 有效期至 ${SimpleDateFormat("yyyy/MM/dd", Locale.CHINA).format(Date(until))}"
    }

    fun hasLapsed(now: Long = System.currentTimeMillis()): Boolean =
        lapsedAt != null || (validUntil?.let { it <= now } ?: false)

    /** Partial days count as a day: "剩余 0 天" while it still works reads as a bug. */
    fun daysLeft(now: Long = System.currentTimeMillis()): Int {
        val until = validUntil ?: return 0
        return max(0, ceil((until - now).toDouble() / DAY_MILLIS).toInt())
    }

    /** The purchase button's title for the current state. */
    fun purchaseTitle(now: Long = System.currentTimeMillis()): String =
        if (isActive(now) && isTrial != true) "续费 1 个月 · ¥1.99" else "开通会员 · ${AccountConfig.PRICE_LABEL}"
}

/**
 * What survives a relaunch: the tokens plus the last profile and membership
 * seen, so the account screen and perks work before the network answers.
 */
@Serializable
data class StoredAccount(
    val tokens: AuthTokens,
    val profile: AccountProfile? = null,
    val membership: Membership = Membership(),
)

/** A browser sign-in waiting for its redirect; persisted across process death. */
@Serializable
data class PendingSignIn(val verifier: String, val state: String)

sealed class AccountError(override val message: String) : Exception(message) {
    /** OAuth error body (`{ error, error_description }`), e.g. invalid_grant. */
    data class OAuth(val code: String, val description: String?) : AccountError(description ?: code)

    /** The Apple ID's email already belongs to an account that never linked Apple. */
    data class AccountExists(val email: String?) :
        AccountError("这个 Apple ID 的邮箱已经注册过账号。请先用原来的方式登录，再到账号中心「登录方式」里绑定 Apple。")

    data class Http(val status: Int, val serverMessage: String?) :
        AccountError(serverMessage ?: "账号中心返回 $status")

    data class Network(val reason: String) : AccountError("连不上账号中心，请检查网络后重试。")

    data object InvalidResponse : AccountError("账号中心暂时不可用，请稍后再试。")

    /** The refresh token is gone for good; only a new sign-in helps. */
    val endsSession: Boolean
        get() = when (this) {
            is OAuth -> code == "invalid_grant"
            is Http -> status == 401
            else -> false
        }
}
