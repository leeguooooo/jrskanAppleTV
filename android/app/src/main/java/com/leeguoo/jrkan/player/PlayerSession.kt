package com.leeguoo.jrkan.player

import android.content.Context
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.leeguoo.jrkan.data.Http
import com.leeguoo.jrkan.data.PlaybackHealthMonitor
import com.leeguoo.jrkan.state.MatchPlaybackModel
import com.leeguoo.jrkan.state.PlaybackRequest
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * The one playing stream, owned above any screen (PlayerSession.swift). The
 * player, its watchdog and the match model outlive the player screen, so
 * picture-in-picture keeps playing — and switching channels when one dies —
 * after the screen is gone.
 */
object PlayerSession {
    private val scope = MainScope()

    private val _model = MutableStateFlow<MatchPlaybackModel?>(null)
    val model: StateFlow<MatchPlaybackModel?> = _model

    /** Drives the full-screen player overlay. */
    private val _isPresented = MutableStateFlow(false)
    val isPresented: StateFlow<Boolean> = _isPresented

    private val _fillsScreen = MutableStateFlow(false)
    val fillsScreen: StateFlow<Boolean> = _fillsScreen

    var isInPictureInPicture = false

    private var player: ExoPlayer? = null
    private var shownRequestId: String? = null
    private var observeJob: Job? = null
    private var watchdog: Job? = null

    @OptIn(UnstableApi::class)
    fun player(context: Context): ExoPlayer = player ?: run {
        val dataSource = OkHttpDataSource.Factory(Http.client).setUserAgent(Http.USER_AGENT)
        ExoPlayer.Builder(context.applicationContext)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource))
            .build()
            .also { exo ->
                exo.addListener(object : Player.Listener {
                    override fun onPlaybackStateChanged(state: Int) {
                        // A live stream that "ends" has stopped, not finished.
                        if (state == Player.STATE_ENDED) stall("播放已停止，请重试或切换线路。")
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        stall("这条线路播放出错：${error.errorCodeName}")
                    }
                })
                player = exo
            }
    }

    fun toggleFill() {
        _fillsScreen.value = !_fillsScreen.value
    }

    /** Called when a match screen's model has a resolved stream to show. */
    fun show(context: Context, model: MatchPlaybackModel) {
        if (_model.value !== model) {
            end()
            _model.value = model
            player(context)
            // Channel switches, fallback and "all channels failed" all arrive as `playback` changes.
            observeJob = scope.launch {
                model.state.distinctUntilChangedBy { it.playback?.id }.collect { apply(context, it.playback) }
            }
        } else if (isInPictureInPicture && !_isPresented.value) {
            // An automatic switch inside the floating window must not pop the player back up.
            return
        }
        _isPresented.value = true
    }

    /** The player screen was closed. Without PiP that ends playback. */
    fun dismiss() {
        _isPresented.value = false
        if (!isInPictureInPicture) end()
    }

    fun end() {
        watchdog?.cancel()
        watchdog = null
        observeJob?.cancel()
        observeJob = null
        player?.run { stop(); clearMediaItems() }
        shownRequestId = null
        _model.value?.stopPlayback()
        _model.value = null
        _isPresented.value = false
    }

    val isPlaying: Boolean get() = player?.isPlaying == true

    private fun apply(context: Context, request: PlaybackRequest?) {
        val model = _model.value ?: return
        if (request == null) {
            // Every channel failed or the model stopped: the error is on the match screen.
            if (shownRequestId != null) end()
            return
        }
        if (request.id == shownRequestId) return
        shownRequestId = request.id
        val match = model.match
        val item = MediaItem.Builder()
            .setUri(request.url)
            .setMimeType(MimeTypes.APPLICATION_M3U8)
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle("${match.homeTeam} vs ${match.awayTeam}")
                    .setSubtitle("${match.league} · ${request.sourceName}")
                    .build()
            )
            .build()
        val exo = player(context)
        exo.setMediaItem(item)
        exo.prepare()
        exo.playWhenReady = true
        startWatchdog(request.id)
    }

    private fun stall(message: String) {
        val request = _model.value?.state?.value?.playback ?: return
        _model.value?.handleStall(message, request.id)
    }

    /** Samples progress twice a second; a paused player is not a stall. */
    private fun startWatchdog(requestId: String) {
        watchdog?.cancel()
        watchdog = scope.launch {
            val health = PlaybackHealthMonitor(seconds())
            while (isActive) {
                delay(500)
                val model = _model.value ?: return@launch
                if (model.state.value.playback?.id != requestId) return@launch
                val exo = player ?: return@launch
                val event = health.sample(
                    now = seconds(),
                    mediaTime = exo.currentPosition / 1000.0,
                    playing = exo.isPlaying,
                    paused = !exo.playWhenReady,
                    ready = exo.playbackState == Player.STATE_READY,
                    itemFailed = exo.playerError != null,
                )
                when (event) {
                    is PlaybackHealthMonitor.Event.Confirmed -> model.confirmPlayback(requestId, event.startupSeconds)
                    PlaybackHealthMonitor.Event.Stalled -> {
                        model.handleStall("这条线路没有画面，正在尝试其他线路。", requestId)
                        return@launch
                    }
                    null -> Unit
                }
            }
        }
    }

    private fun seconds() = SystemClock.elapsedRealtime() / 1000.0
}
