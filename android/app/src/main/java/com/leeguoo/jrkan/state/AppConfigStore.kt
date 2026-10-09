package com.leeguoo.jrkan.state

import android.content.Context
import android.content.SharedPreferences
import com.leeguoo.jrkan.BuildConfig
import com.leeguoo.jrkan.data.AppConfig
import com.leeguoo.jrkan.data.Http
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * The latest remote config (AppConfigStore in AppConfig.swift): the cached
 * copy at launch, the fetched one after. A failed fetch keeps what was there;
 * with nothing cached the built-in defaults apply.
 */
object AppConfigStore {
    const val ENDPOINT = "https://config.leeguoo.com/v1/jrkan.json"
    private const val REFRESH_INTERVAL_MS = 10 * 60 * 1000L
    private const val CACHE_KEY = "remoteConfig.jrkan"

    private val _config = MutableStateFlow(AppConfig())
    val config: StateFlow<AppConfig> = _config

    /** Set from the account session; slots can hide for members. */
    val isMember = MutableStateFlow(false)

    private var prefs: SharedPreferences? = null
    private var lastFetch = 0L

    fun init(context: Context) {
        val prefs = context.getSharedPreferences("jrkan-remote-config", Context.MODE_PRIVATE)
        this.prefs = prefs
        prefs.getString(CACHE_KEY, null)?.let(AppConfig::parse)?.let { _config.value = it }
        // Debug builds: files/config-override.json pins a config for screenshots, skipping the network
        // (`adb shell run-as com.leeguoo.jrskan` to put it there).
        if (BuildConfig.DEBUG) {
            java.io.File(context.filesDir, "config-override.json").takeIf { it.exists() }
                ?.let { AppConfig.parse(it.readText()) }
                ?.let { _config.value = it; lastFetch = Long.MAX_VALUE / 2 }
        }
    }

    /** Launch and return to the foreground; at most every ten minutes. */
    suspend fun refreshIfStale(now: Long = System.currentTimeMillis()) {
        if (lastFetch != 0L && (lastFetch > now || now - lastFetch < REFRESH_INTERVAL_MS)) return
        lastFetch = now
        refresh()
    }

    suspend fun refresh() {
        val page = runCatching { Http.get(ENDPOINT, timeoutSeconds = 10) }.getOrNull() ?: return
        if (page.status != 200) return
        val text = page.utf8() ?: return
        val fetched = AppConfig.parse(text) ?: return
        prefs?.edit()?.putString(CACHE_KEY, text)?.apply()
        _config.value = fetched
    }
}
