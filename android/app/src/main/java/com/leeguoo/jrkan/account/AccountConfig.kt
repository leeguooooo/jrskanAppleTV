package com.leeguoo.jrkan.account

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl

/**
 * The leeguoo account center (account.leeguoo.com) is the one identity
 * provider for every app; JRKAN is just another OIDC client of it. Accounts,
 * sign-in methods and memberships live there — the app only keeps tokens.
 * Port of App/Sources/Shared/Account/AccountAPI.swift (AccountConfig).
 */
object AccountConfig {
    val issuer: HttpUrl = "https://account.leeguoo.com/".toHttpUrl()

    /**
     * Android reuses the iOS public PKCE client: its redirect URI
     * (com.leeguoo.jrskan.tv:/oauth/callback) is already registered with the
     * account center, and AndroidManifest.xml has a VIEW intent-filter on
     * MainActivity for exactly that scheme + path, so the browser hands the
     * callback straight back to the app.
     */
    const val CLIENT_ID = "leeguoo-jrkan-ios"
    const val CALLBACK_SCHEME = "com.leeguoo.jrskan.tv"
    const val CALLBACK_PATH = "/oauth/callback"
    const val REDIRECT_URI = "$CALLBACK_SCHEME:$CALLBACK_PATH"
    const val SCOPE = "openid profile email"

    /** Either the cross-app membership or a JRKAN-only plan unlocks the perks. */
    val membershipKeys: Set<String> = setOf("membership.all_apps", "jrkan.premium")

    val manageUrl: String = issuer.resolve("account").toString()

    /**
     * Hosted purchase page: signs in if needed, then hands off to 爱发电
     * (WeChat Pay / Alipay). Payment never happens inside the app.
     */
    val membershipUrl: String = issuer.resolve("membership/jrkan").toString()
    const val PRICE_LABEL = "¥1.99/月"
}
