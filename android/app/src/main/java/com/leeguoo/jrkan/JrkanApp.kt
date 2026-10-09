package com.leeguoo.jrkan

import android.app.Application
import com.leeguoo.jrkan.account.AccountSession
import com.leeguoo.jrkan.account.SharedPreferencesAccountStore
import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.recording.Recordings
import com.leeguoo.jrkan.state.AppConfigStore
import com.leeguoo.jrkan.state.MatchListModel
import com.leeguoo.jrkan.state.Preferences
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch

/** App-wide singletons: one schedule, one set of preferences, one account. */
class JrkanApp : Application() {
    val scope = MainScope()
    lateinit var preferences: Preferences
        private set
    lateinit var listModel: MatchListModel
        private set
    lateinit var account: AccountSession
        private set

    override fun onCreate() {
        super.onCreate()
        Recordings.init(this)
        preferences = Preferences.open(this)
        listModel = MatchListModel(preferences, scope)
        account = AccountSession(store = SharedPreferencesAccountStore(getSharedPreferences("jrkan-account", MODE_PRIVATE)))
        AppConfigStore.init(this)
        scope.launch { account.account.collect { AppConfigStore.isMember.value = account.isMember } }
    }

    /** Launch and return-to-foreground: pick up membership changes made elsewhere. */
    fun refreshAccountIfStale() {
        scope.launch { account.refreshIfStale() }
    }

    fun refreshConfigIfStale() {
        scope.launch { AppConfigStore.refreshIfStale() }
    }

    fun handleSignInRedirect(uri: String) {
        scope.launch { account.handleRedirect(uri) }
    }

    private val opened = mutableMapOf<String, LiveMatch>()

    /** The match a screen was opened with, so the detail route can find it by id. */
    fun rememberMatch(match: LiveMatch) {
        opened[match.id] = match
    }

    fun findMatch(id: String): LiveMatch? =
        listModel.state.value.matches.firstOrNull { it.id == id }
            ?: opened[id]
            ?: preferences.recentWatches.value.firstOrNull { it.id == id }?.match
}
