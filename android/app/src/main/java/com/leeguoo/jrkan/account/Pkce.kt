package com.leeguoo.jrkan.account

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/** RFC 7636 proof key for the browser sign-in. */
data class Pkce(val verifier: String = randomUrlSafe(32)) {
    val challenge: String = base64Url(MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.UTF_8)))

    companion object {
        private val random = SecureRandom()

        fun randomUrlSafe(bytes: Int): String = base64Url(ByteArray(bytes).also(random::nextBytes))

        fun base64Url(data: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(data)
    }
}
