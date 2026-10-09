package com.leeguoo.jrkan.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.ViewGroup
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.StopCircle
import androidx.compose.material.icons.outlined.Videocam
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import com.leeguoo.jrkan.player.PlayerSession
import com.leeguoo.jrkan.recording.HlsRecorder
import com.leeguoo.jrkan.recording.RecordingInfo
import com.leeguoo.jrkan.recording.RecordingService
import com.leeguoo.jrkan.recording.Recordings
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Recordings on this device (RecordingsScreen.swift): running ones first,
 * then finished ones, newest first. Tapping plays it, a running one included.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecordingsScreen(onBack: () -> Unit) {
    val recordings by Recordings.recordings.collectAsState()
    val active by Recordings.active.collectAsState()
    val exporting by Recordings.exporting.collectAsState()
    val exportErrors by Recordings.exportErrors.collectAsState()
    val context = LocalContext.current
    var playing by remember { mutableStateOf<RecordingInfo?>(null) }
    var confirmDelete by remember { mutableStateOf<RecordingInfo?>(null) }

    val running = recordings.filter { it.id in active }
    val finished = recordings.filter { it.id !in active }

    Scaffold(
        containerColor = Palette.background,
        topBar = {
            TopAppBar(
                title = { Text("录像") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Palette.background),
            )
        },
    ) { padding ->
        if (recordings.isEmpty()) {
            EmptyState(
                Icons.Outlined.Videocam, "还没有录像",
                "播放比赛时点顶部的录像按钮，关掉播放器、锁屏或切到别的应用都会继续录。",
                modifier = Modifier.padding(padding),
            )
            return@Scaffold
        }
        LazyColumn(Modifier.padding(padding).fillMaxSize(), contentPadding = listContentPadding) {
            if (running.isNotEmpty()) {
                item { GroupTitle("正在录制") }
                running.forEachIndexed { index, info ->
                    item(key = "run-${info.id}") {
                        GroupedCell(index, running.size, onClick = { playing = info }) {
                            RecordingRow(info, active[info.id]) {
                                IconButton(onClick = { Recordings.stop(info.id) }) {
                                    Icon(Icons.Outlined.StopCircle, "停止录像", tint = Palette.live)
                                }
                            }
                        }
                    }
                }
            }
            if (finished.isNotEmpty()) {
                item { GroupTitle("已录制") }
                finished.forEachIndexed { index, info ->
                    item(key = "done-${info.id}") {
                        GroupedCell(index, finished.size, onClick = { playing = info }, onLongClick = { confirmDelete = info }) {
                            RecordingRow(info, null, exporting[info.id], exportErrors[info.id]) {
                                val progress = exporting[info.id]
                                when {
                                    progress != null -> CircularProgressIndicator(
                                        progress = { progress.toFloat() }, modifier = Modifier.padding(12.dp).size(22.dp), strokeWidth = 2.dp,
                                    )
                                    info.videoUri != null -> IconButton(onClick = { share(context, info) }) {
                                        Icon(Icons.Outlined.Share, "分享", tint = Palette.accent)
                                    }
                                    exportErrors[info.id] != null -> IconButton(onClick = { Recordings.export(info.id) }) {
                                        Icon(Icons.Outlined.Refresh, "重新生成视频", tint = Palette.tertiaryText)
                                    }
                                }
                                IconButton(onClick = { confirmDelete = info }) {
                                    Icon(Icons.Outlined.Delete, "删除", tint = Palette.tertiaryText)
                                }
                            }
                        }
                    }
                }
                item {
                    Text(
                        "录完会自动生成带水印的 MP4，保存在相册「影片/JRKAN」里，点分享就能发出去。录像只保存在本机，不会上传。",
                        fontSize = 12.sp, color = Palette.tertiaryText,
                        modifier = Modifier.padding(horizontal = 32.dp, vertical = 8.dp),
                    )
                }
            }
        }
    }

    confirmDelete?.let { info ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text("删除录像？") },
            text = { Text("「${info.title}」，${RecordingService.size(info.bytes)}。删除后无法恢复。") },
            confirmButton = {
                TextButton(onClick = { Recordings.delete(info.id); confirmDelete = null }) { Text("删除", color = Palette.live) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("取消") } },
        )
    }

    playing?.let { info -> RecordingPlayer(info, onClose = { playing = null }) }
}

@Composable
private fun RecordingRow(
    info: RecordingInfo,
    recorder: HlsRecorder?,
    progress: Double? = null,
    error: String? = null,
    trailing: @Composable () -> Unit,
) {
    val phase = recorder?.phase?.collectAsState()?.value
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp, top = 10.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (recorder != null) Icon(Icons.Filled.FiberManualRecord, null, tint = Palette.live, modifier = Modifier.size(12.dp))
                Text(info.title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Text(
                "${info.league} · ${info.channelName} · ${dateFormat.format(Date(info.startedAt))}",
                fontSize = 12.sp, color = Palette.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            val parts = mutableListOf(RecordingService.duration(info.duration))
            when {
                progress != null -> parts += "正在生成视频 ${(progress * 100).toInt()}%"
                error != null -> parts += error
                info.videoUri != null -> parts += "MP4"
                else -> parts += RecordingService.size(info.bytes)
            }
            if (info.gapCount > 0) parts += "${info.gapCount} 处缺口"
            when {
                phase == HlsRecorder.Phase.Reconnecting -> parts += "正在重新连接…"
                recorder != null -> parts += "录制中"
                info.endReason != null && info.videoUri == null && progress == null -> parts += info.endReason
            }
            Text(
                parts.joinToString(" · "), fontSize = 12.sp,
                color = if (phase == HlsRecorder.Phase.Reconnecting) Color(0xFFFF9F0A) else Palette.tertiaryText,
                maxLines = 2,
            )
        }
        trailing()
    }
}

/** Full-screen playback of one recording, with its own player (the live one stays put). */
@Composable
private fun RecordingPlayer(info: RecordingInfo, onClose: () -> Unit) {
    val context = LocalContext.current
    val player = remember(info.id) {
        PlayerSession.pauseForOtherPlayback()
        ExoPlayer.Builder(context).build().apply {
            setMediaItem(
                MediaItem.Builder()
                    .setUri(Recordings.playbackUri(info))
                    .apply { if (info.videoUri == null) setMimeType(MimeTypes.APPLICATION_M3U8) }
                    .build()
            )
            prepare()
            playWhenReady = true
        }
    }
    DisposableEffect(player) { onDispose { player.release() } }
    BackHandler(onBack = onClose)

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                PlayerView(ctx).apply {
                    layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                    this.player = player
                }
            },
        )
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().background(Color.Black.copy(alpha = 0.45f)).padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "关闭", tint = Color.White) }
            Text(info.title, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** The system share sheet for the recording's MP4. */
private fun share(context: Context, info: RecordingInfo) {
    val uri = info.videoUri?.let(Uri::parse) ?: return
    val send = Intent(Intent.ACTION_SEND)
        .setType("video/mp4")
        .putExtra(Intent.EXTRA_STREAM, uri)
        .putExtra(Intent.EXTRA_TITLE, info.title)
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    context.startActivity(Intent.createChooser(send, "分享录像").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
}

private val dateFormat = SimpleDateFormat("M月d日 HH:mm", Locale.CHINA)
