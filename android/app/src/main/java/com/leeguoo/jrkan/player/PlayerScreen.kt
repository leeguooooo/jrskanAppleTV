@file:kotlin.OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.leeguoo.jrkan.player

import android.view.ViewGroup
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.systemBarsIgnoringVisibility
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.outlined.FiberManualRecord
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.leeguoo.jrkan.recording.HlsRecorder
import com.leeguoo.jrkan.recording.RecordingService
import com.leeguoo.jrkan.recording.Recordings
import com.leeguoo.jrkan.state.MatchPlaybackModel

/**
 * Full-screen player. Media3's own controller does play/pause and the
 * timeline; on top sit close, channel switching, fill and PiP, plus the
 * same "leeguoo.com" watermark as the Apple players.
 */
private val barsInsets: WindowInsets
    @Composable get() = WindowInsets.systemBarsIgnoringVisibility.union(WindowInsets.displayCutout)

@OptIn(UnstableApi::class)
@Composable
fun PlayerScreen(model: MatchPlaybackModel, inPictureInPicture: Boolean, onPictureInPicture: () -> Unit) {
    val context = LocalContext.current
    val state by model.state.collectAsState()
    val fills by PlayerSession.fillsScreen.collectAsState()
    var controlsVisible by remember { mutableStateOf(true) }
    val player = remember { PlayerSession.player(context) }

    BackHandler { PlayerSession.dismiss() }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                PlayerView(ctx).apply {
                    layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                    this.player = player
                    setShowNextButton(false)
                    setShowPreviousButton(false)
                    setShowFastForwardButton(false)
                    setShowRewindButton(false)
                    setControllerVisibilityListener(PlayerView.ControllerVisibilityListener { visibility ->
                        controlsVisible = visibility == android.view.View.VISIBLE
                    })
                }
            },
            update = { view ->
                view.useController = !inPictureInPicture
                view.resizeMode = if (fills) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
            },
        )

        if (!inPictureInPicture) {
            Text(
                "leeguoo.com",
                color = Color.White.copy(alpha = 0.55f),
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                // Sits above Media3's bottom bar so it never covers the settings gear.
                modifier = Modifier.align(Alignment.BottomEnd).windowInsetsPadding(barsInsets).padding(end = 20.dp, bottom = 64.dp),
            )
        }

        if (!inPictureInPicture && controlsVisible) {
            TopControls(model, state, fills, onPictureInPicture)
        }

        val notice = state.notice ?: if (state.resolvingIndex != null) "正在切换线路…" else null
        if (notice != null && !inPictureInPicture) {
            Text(
                notice,
                color = Color.White,
                fontSize = 13.sp,
                modifier = Modifier
                    .align(Alignment.Center)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Color.Black.copy(alpha = 0.6f))
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            )
        }
    }
}

@Composable
private fun TopControls(model: MatchPlaybackModel, state: MatchPlaybackModel.State, fills: Boolean, onPictureInPicture: () -> Unit) {
    var channelMenu by remember { mutableStateOf(false) }
    val match = model.match
    Row(
        Modifier
            .fillMaxWidth()
            .background(Color.Black.copy(alpha = 0.45f))
            // The bars are hidden while playing; pad for them anyway so the
            // buttons are not inside the swipe-to-reveal edge, which eats taps.
            .windowInsetsPadding(barsInsets)
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = { PlayerSession.dismiss() }) { Icon(Icons.Filled.Close, "关闭", tint = Color.White) }
        Column(Modifier.weight(1f).padding(horizontal = 4.dp)) {
            Text("${match.homeTeam} vs ${match.awayTeam}", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            state.playback?.let { Text("线路 ${it.index + 1} · ${it.sourceName}", color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp, maxLines = 1) }
        }
        Box {
            IconButton(onClick = { channelMenu = true }) { Icon(Icons.Filled.SwapHoriz, "切换线路", tint = Color.White) }
            DropdownMenu(expanded = channelMenu, onDismissRequest = { channelMenu = false }) {
                model.resolvedChannels.forEachIndexed { index, source ->
                    DropdownMenuItem(
                        text = {
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text("${index + 1}")
                                Text(source.name, fontWeight = if (state.playback?.index == index) FontWeight.Bold else FontWeight.Normal)
                            }
                        },
                        onClick = { channelMenu = false; model.startPlayback(index) },
                    )
                }
            }
        }
        RecordButton(model, state)
        IconButton(onClick = { PlayerSession.toggleFill() }) {
            Icon(if (fills) Icons.Filled.FullscreenExit else Icons.Filled.Fullscreen, if (fills) "完整画面" else "铺满屏幕", tint = Color.White)
        }
        IconButton(onClick = onPictureInPicture) { Icon(Icons.Filled.PictureInPictureAlt, "画中画", tint = Color.White) }
    }
}

/**
 * Starts a recording of what is playing, or shows the running one with stop
 * and "record this channel instead" once the viewer has switched channels.
 * The first recording asks for notification permission: the foreground
 * notification is where a background recording is seen and stopped.
 */
@Composable
private fun RecordButton(model: MatchPlaybackModel, state: MatchPlaybackModel.State) {
    val context = LocalContext.current
    val active by Recordings.active.collectAsState()
    val recorder = active.values.firstOrNull { it.info.value.matchId == model.match.id }
    var menu by remember { mutableStateOf(false) }

    fun start() {
        val playback = state.playback ?: return
        Recordings.start(model.match, model.resolvedChannels, playback.index, playback.url)
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { start() }

    if (recorder == null) {
        IconButton(
            enabled = state.playback != null,
            onClick = {
                if (Build.VERSION.SDK_INT >= 33 &&
                    ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                ) {
                    permission.launch(Manifest.permission.POST_NOTIFICATIONS)
                } else {
                    start()
                }
            },
        ) { Icon(Icons.Outlined.FiberManualRecord, "录像", tint = Color.White) }
        return
    }

    val info by recorder.info.collectAsState()
    val recordingIndex by recorder.sourceIndex.collectAsState()
    val phase by recorder.phase.collectAsState()
    Box {
        Row(
            Modifier
                .clip(RoundedCornerShape(50))
                .background(Color.Black.copy(alpha = 0.35f))
                .clickable { menu = true }
                .padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(Icons.Filled.FiberManualRecord, null, tint = if (phase == HlsRecorder.Phase.Reconnecting) Color(0xFFFF9F0A) else Color(0xFFFF453A), modifier = Modifier.size(10.dp))
            Text(RecordingService.duration(info.duration), color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            val playing = state.playback
            if (playing != null && playing.index != recordingIndex && playing.index in recorder.sources.indices) {
                DropdownMenuItem(
                    text = { Text("改录当前线路「${playing.sourceName}」") },
                    onClick = { menu = false; recorder.switchSource(playing.index) },
                )
            }
            DropdownMenuItem(text = { Text("停止录像") }, onClick = { menu = false; Recordings.stop(recorder.id) })
        }
    }
}
