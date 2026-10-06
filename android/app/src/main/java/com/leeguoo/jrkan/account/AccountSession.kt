package com.leeguoo.jrkan.account

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.net.URLDecoder

/**
 * The signed-in state the whole app reads. Signing in is optional: nothing
 * in the app needs an account except membership perks. Port of
 * AccountSession.swift; one instance per process (hold it in the Application).
 */
class AccountSession(
    val api: AccountApi = AccountApi(),
    private val store: AccountStore,
    private val now: () -> Long = System::currentTimeMillis,
    /** Debug mocks never talk to the server. */
    private val offline: Boolean = false,
    /** Owns the shared refresh so one cancelled caller cannot fail the others. */
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
) {
    private val _account = MutableStateFlow(store.load())
    val account: StateFlow<StoredAccount?> = _account.asStateFlow()

    private val _isSigningIn = MutableStateFlow(false)
    val isSigningIn: StateFlow<Boolean> = _isSigningIn.asStateFlow()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    /** The last failure worth showing next to the sign-in controls. */
    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()

    val isSignedIn: Boolean get() = _account.value != null
    val profile: AccountProfile? get() = _account.value?.profile
    val membership: Membership get() = _account.value?.membership ?: Membership()
    val isMember: Boolean get() = membership.isActive(now())

    private val refreshLock = Mutex()
    private var refreshJob: Deferred<AuthTokens>? = null

    @Volatile private var pending: PendingSignIn? = null

    /** Lets the UI show or dismiss its own message (e.g. a failed browser launch). */
    fun reportError(message: String?) {
        _lastError.value = message
    }

    // MARK: Lifecycle

    /**
     * Launch and return-to-foreground: pick up membership changes made on
     * another device or in the account center.
     */
    suspend fun refreshIfStale(maxAgeMillis: Long = 30 * 60 * 1000L) {
        val stored = _account.value ?: return
        val checked = stored.membership.checkedAt
        if (checked != null && now() - checked < maxAgeMillis && stored.profile != null) return
        refreshAccount()
    }

    suspend fun refreshAccount() {
        if (_account.value == null || offline) return
        if (!_isRefreshing.compareAndSet(expect = false, update = true)) return
        // A refresh failure already ended the session inside validAccessToken
        // (only if the same account was still signed in); this tracks which
        // account a later 401 from userinfo or entitlements belongs to.
        var signedInAs: String? = null
        try {
            val token = validAccessToken()
            signedInAs = _account.value?.tokens?.refreshToken
            val (newProfile, newMembership) = coroutineScope {
                val profile = async { api.userInfo(token) }
                val membership = async { api.membership(token) }
                profile.await() to membership.await()
            }
            val current = _account.value ?: return
            persist(current.copy(profile = newProfile, membership = newMembership))
        } catch (e: CancellationException) {
            throw e
        } catch (e: AccountError) {
            // Unlike the Swift original, never clear an account signed in while this ran.
            if (e.endsSession && signedInAs != null && _account.value?.tokens?.refreshToken == signedInAs) {
                endSession(SESSION_EXPIRED)
            }
            // Otherwise offline: the cached profile and membership keep working.
        } catch (_: Exception) {
        } finally {
            _isRefreshing.value = false
        }
    }

    /**
     * Every API call goes through here; concurrent callers share one refresh
     * because the server treats a reused refresh token as theft.
     */
    suspend fun validAccessToken(): String {
        val job = refreshLock.withLock {
            val current = _account.value ?: throw AccountError.Http(401, null)
            if (!current.tokens.needsRefresh(now())) return current.tokens.accessToken
            refreshJob?.takeIf { it.isActive } ?: startRefresh(current.tokens.refreshToken).also { refreshJob = it }
        }
        return job.await().accessToken
    }

    /**
     * Runs in the session's own scope and persists the rotated tokens itself,
     * so a caller that goes away mid-refresh cannot lose them. The outcome is
     * applied under [refreshLock]: a caller that read the old tokens under the
     * lock is guaranteed to still see this job active and join it.
     */
    private fun startRefresh(used: String): Deferred<AuthTokens> = scope.async {
        val result = runCatching { api.refresh(used) }
        refreshLock.withLock {
            val tokens = result.getOrElse { error ->
                if (error is AccountError && error.endsSession && _account.value?.tokens?.refreshToken == used) {
                    endSession(SESSION_EXPIRED)
                }
                throw error
            }
            // Signed out (or in as someone else) while the request was out.
            val latest = _account.value
            if (latest == null || latest.tokens.refreshToken != used) throw AccountError.Http(401, null)
            persist(latest.copy(tokens = tokens))
            tokens
        }
    }

    // MARK: Signing in

    /** Final step of every sign-in path. */
    suspend fun complete(tokens: AuthTokens) {
        _lastError.value = null
        persist(StoredAccount(tokens = tokens))
        refreshAccount()
    }

    /** Wraps a token exchange with the busy flag and error reporting. */
    suspend fun run(exchange: suspend () -> AuthTokens) {
        _isSigningIn.value = true
        _lastError.value = null
        try {
            complete(exchange())
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _lastError.value = e.message ?: e.toString()
        } finally {
            _isSigningIn.value = false
        }
    }

    /**
     * Starts the account-center sign-in (password, Google, GitHub, Apple on
     * the web). Returns the authorize URL to open in a Custom Tab; the PKCE
     * verifier and state are kept in memory and in the store so the redirect
     * still completes if the process dies while the browser is in front.
     */
    fun beginBrowserSignIn(): String {
        val pkce = Pkce()
        val state = Pkce.randomUrlSafe(16)
        val next = PendingSignIn(verifier = pkce.verifier, state = state)
        pending = next
        store.savePending(next)
        _lastError.value = null
        return api.authorizeUrl(pkce, state)
    }

    /**
     * Feed every incoming VIEW intent's data string here. Returns false when
     * the URI is not the sign-in callback (nothing happens); otherwise checks
     * state, then exchanges the code (or reports the error) and returns true.
     */
    suspend fun handleRedirect(uri: String): Boolean {
        if (!isCallback(uri)) return false
        val query = parseQuery(uri)
        val expected = pending ?: store.loadPending()
        if (expected == null || query["state"] != expected.state) {
            _lastError.value = "登录回调校验失败，请重试。"
            return true
        }
        // The code and verifier are single-use either way.
        pending = null
        store.savePending(null)
        val code = query["code"]
        if (code == null) {
            query["error"]?.let { _lastError.value = query["error_description"] ?: it }
            return true
        }
        run { api.exchangeCode(code, Pkce(expected.verifier)) }
        return true
    }

    // MARK: Signing out

    suspend fun signOut() {
        val current = _account.value ?: return
        endSession(null)
        api.revoke(current.tokens.refreshToken)
    }

    private fun endSession(message: String?) {
        store.clear()
        _account.value = null
        _lastError.value = message
    }

    private fun persist(account: StoredAccount) {
        if (!offline) store.save(account)
        _account.update { account }
    }

    companion object {
        const val SESSION_EXPIRED = "登录已过期，请重新登录。"

        internal fun isCallback(uri: String): Boolean {
            val base = uri.substringBefore('#').substringBefore('?')
            return base.equals(AccountConfig.REDIRECT_URI, ignoreCase = true) ||
                base.equals("${AccountConfig.CALLBACK_SCHEME}://${AccountConfig.CALLBACK_PATH}", ignoreCase = true)
        }

        /** android.net.Uri is a stub in JVM unit tests, so the query is split by hand. */
        internal fun parseQuery(uri: String): Map<String, String> {
            val query = uri.substringBefore('#').substringAfter('?', "")
            if (query.isEmpty()) return emptyMap()
            return query.split('&').filter { it.isNotEmpty() }.associate { pair ->
                val name = pair.substringBefore('=')
                val value = pair.substringAfter('=', "")
                URLDecoder.decode(name, "UTF-8") to URLDecoder.decode(value, "UTF-8")
            }
        }

        /**
         * Debug-only fake account (`mode`: trial | member | expired | free) so
         * the screens can be checked without a real sign-in. Never hits the network.
         */
        fun mock(mode: String, now: Long = System.currentTimeMillis()): AccountSession {
            val active = mode == "member" || mode == "trial"
            val account = StoredAccount(
                tokens = AuthTokens("mock", "mock", null, Long.MAX_VALUE),
                profile = AccountProfile(sub = "mock", email = "viewer@example.com", name = "测试用户"),
                membership = Membership(
                    activeKeys = if (active) setOf("jrkan.premium") else emptySet(),
                    validUntil = if (active) now + (86_400_000L * (if (mode == "trial") 76.5 else 200.0)).toLong() else null,
                    checkedAt = now,
                    isTrial = mode == "trial",
                    lapsedAt = if (mode == "expired") now - 86_400_000L * 3 else null,
                ),
            )
            return AccountSession(store = MemoryAccountStore(account), offline = true)
        }
    }
}
