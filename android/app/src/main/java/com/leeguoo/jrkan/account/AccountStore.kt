package com.leeguoo.jrkan.account

import android.content.Context
import android.content.SharedPreferences
import kotlinx.serialization.json.Json

interface AccountStore {
    fun load(): StoredAccount?
    fun save(account: StoredAccount)
    fun clear()

    /** The browser sign-in in progress, so it survives process death while the browser is open. */
    fun loadPending(): PendingSignIn?
    fun savePending(pending: PendingSignIn?)
}

/**
 * JSON in app-private SharedPreferences. iOS keeps tokens in the Keychain;
 * on Android the app's private data directory is already sandboxed from
 * other apps, and the manifest sets allowBackup="false", so the tokens do
 * not leave the device in backups either.
 */
class SharedPreferencesAccountStore(private val prefs: SharedPreferences) : AccountStore {
    constructor(context: Context) : this(context.getSharedPreferences("account", Context.MODE_PRIVATE))

    private val json = Json { ignoreUnknownKeys = true }

    override fun load(): StoredAccount? = read(ACCOUNT)

    override fun save(account: StoredAccount) {
        prefs.edit().putString(ACCOUNT, json.encodeToString(StoredAccount.serializer(), account)).apply()
    }

    override fun clear() {
        prefs.edit().remove(ACCOUNT).apply()
    }

    override fun loadPending(): PendingSignIn? = read(PENDING)

    override fun savePending(pending: PendingSignIn?) {
        val editor = prefs.edit()
        if (pending == null) editor.remove(PENDING)
        else editor.putString(PENDING, json.encodeToString(PendingSignIn.serializer(), pending))
        // The browser opens right after this; the process may die before an async apply lands.
        editor.commit()
    }

    private inline fun <reified T> read(key: String): T? {
        val text = prefs.getString(key, null) ?: return null
        return try {
            json.decodeFromString<T>(text)
        } catch (_: IllegalArgumentException) {
            null
        }
    }

    private companion object {
        const val ACCOUNT = "stored_account"
        const val PENDING = "pending_sign_in"
    }
}

class MemoryAccountStore(@Volatile var stored: StoredAccount? = null) : AccountStore {
    @Volatile var pending: PendingSignIn? = null

    override fun load(): StoredAccount? = stored
    override fun save(account: StoredAccount) {
        stored = account
    }

    override fun clear() {
        stored = null
    }

    override fun loadPending(): PendingSignIn? = pending
    override fun savePending(pending: PendingSignIn?) {
        this.pending = pending
    }
}
