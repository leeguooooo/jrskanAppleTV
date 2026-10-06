package com.leeguoo.jrkan

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.leeguoo.jrkan.player.PlayerScreen
import com.leeguoo.jrkan.player.PlayerSession
import com.leeguoo.jrkan.state.MatchPlaybackModel
import com.leeguoo.jrkan.ui.AccountRoute
import com.leeguoo.jrkan.ui.AccountSummary
import com.leeguoo.jrkan.ui.HomeScreen
import com.leeguoo.jrkan.ui.JrkanTheme
import com.leeguoo.jrkan.ui.MatchDetailScreen
import com.leeguoo.jrkan.ui.Palette
import com.leeguoo.jrkan.ui.SettingsScreen
import java.net.URLDecoder
import java.net.URLEncoder

class MainActivity : ComponentActivity() {
    private val app get() = application as JrkanApp
    private var inPip by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        handleRedirect(intent)

        // Refresh on the way back to the foreground, stop polling in the background.
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                app.listModel.startAutoRefresh()
                app.listModel.refreshIfStale()
                app.refreshAccountIfStale()
            }

            override fun onStop(owner: LifecycleOwner) = app.listModel.stopAutoRefresh()
        })

        setContent {
            JrkanTheme {
                val presented by PlayerSession.isPresented.collectAsState()
                val playerModel by PlayerSession.model.collectAsState()
                Box(Modifier.fillMaxSize().background(Palette.background)) {
                    if (!inPip) AppNavigation()
                    val model = playerModel
                    if ((presented || inPip) && model != null) {
                        PlayerScreen(model, inPip, onPictureInPicture = ::enterPip)
                    }
                }
                LaunchedEffect(presented) { applyPlayerChrome(presented) }
            }
        }
    }

    @Composable
    private fun AppNavigation() {
        val nav = rememberNavController()
        val context = LocalContext.current
        NavHost(nav, startDestination = "home") {
            composable("home") {
                HomeScreen(
                    app.listModel,
                    onOpenMatch = { match, autoplay ->
                        app.rememberMatch(match)
                        nav.navigate("match/${URLEncoder.encode(match.id, "UTF-8")}?autoplay=$autoplay")
                    },
                    onOpenSettings = { nav.navigate("settings") },
                )
            }
            composable(
                "match/{id}?autoplay={autoplay}",
                arguments = listOf(
                    navArgument("id") { type = NavType.StringType },
                    navArgument("autoplay") { type = NavType.BoolType; defaultValue = false },
                ),
            ) { entry ->
                val id = URLDecoder.decode(entry.arguments?.getString("id").orEmpty(), "UTF-8")
                val autoplay = entry.arguments?.getBoolean("autoplay") ?: false
                val match = app.findMatch(id)
                if (match == null) {
                    LaunchedEffect(Unit) { nav.popBackStack() }
                    return@composable
                }
                val playback = remember(id) { MatchPlaybackModel(match, app.preferences, app.scope) }
                // Resolve first, present second: the player appears once a channel has a stream.
                val state by playback.state.collectAsState()
                LaunchedEffect(state.playback?.id) {
                    if (state.playback != null) PlayerSession.show(context, playback)
                }
                MatchDetailScreen(playback, app.listModel, autoplay, onBack = { nav.popBackStack() })
            }
            composable("settings") {
                SettingsScreen(
                    app.listModel,
                    accountSummary = { AccountSummary(app.account) },
                    onOpenAccount = { nav.navigate("account") },
                    onBack = { nav.popBackStack() },
                )
            }
            composable("account") {
                AccountRoute(app.account, onBack = { nav.popBackStack() })
            }
        }
    }

    /** Landscape and no system bars while the player is up; back to normal after. */
    private fun applyPlayerChrome(playing: Boolean) {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        if (playing) {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
        updatePipParams(playing)
    }

    private fun pipParams(autoEnter: Boolean): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) builder.setAutoEnterEnabled(autoEnter)
        return builder.build()
    }

    private fun updatePipParams(playing: Boolean) {
        setPictureInPictureParams(pipParams(playing))
    }

    private fun enterPip() {
        enterPictureInPictureMode(pipParams(true))
    }

    /** Before Android 12 there is no auto-enter; leaving the app with a stream up goes to PiP. */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S && PlayerSession.isPresented.value && PlayerSession.isPlaying) enterPip()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPip = isInPictureInPictureMode
        PlayerSession.isInPictureInPicture = isInPictureInPictureMode
    }

    override fun onStop() {
        super.onStop()
        // Swiping the PiP window away stops the activity while still in PiP: that is "close".
        if (inPip) {
            PlayerSession.isInPictureInPicture = false
            PlayerSession.end()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleRedirect(intent)
    }

    /** Account-center sign-in comes back as com.leeguoo.jrskan.tv:/oauth/callback?code=…&state=… */
    private fun handleRedirect(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme == "com.leeguoo.jrskan.tv") app.handleSignInRedirect(data.toString())
    }
}
