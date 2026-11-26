package com.leeguoo.jrkan.ui

import android.view.ViewGroup
import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.outlined.VideoLibrary
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import coil3.compose.AsyncImage
import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.ReplayGroup
import com.leeguoo.jrkan.data.ReplayParsing
import com.leeguoo.jrkan.data.ReplayStream
import com.leeguoo.jrkan.data.ReplayVideo
import com.leeguoo.jrkan.data.userMessage
import com.leeguoo.jrkan.player.PlayerSession
import com.leeguoo.jrkan.state.MatchReplays
import com.leeguoo.jrkan.state.ReplayLibrary
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 回看 (ReplaysScreen.swift): recent recordings fans post on Weibo, a row per game. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReplaysScreen(onOpenGroup: (ReplayGroup) -> Unit, onBack: () -> Unit, onOpenDownloads: () -> Unit = {}) {
    val state by ReplayLibrary.state.collectAsState()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var accepted by remember { mutableStateOf(ReplayDisclaimer.isAccepted(context)) }
    var readsDisclaimer by remember { mutableStateOf(false) }
    if (!accepted) {
        ReplayDisclaimerDialog(onAgree = { ReplayDisclaimer.accept(context); accepted = true }, onDismiss = onBack)
    } else if (readsDisclaimer) {
        ReplayDisclaimerDialog(onAgree = null, onDismiss = { readsDisclaimer = false })
    }
    LaunchedEffect(Unit) { ReplayLibrary.refreshIfStale() }

    Scaffold(
        containerColor = Palette.background,
        topBar = {
            TopAppBar(
                title = { Text("回看") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                actions = { IconButton(onClick = onOpenDownloads) { Icon(Icons.Filled.Download, "已下载", tint = Palette.secondaryText) } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Palette.background),
            )
        },
    ) { padding ->
        when {
            state.groups.isEmpty() && state.isLoading -> Box(Modifier.padding(padding).fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Palette.accent)
            }
            state.groups.isEmpty() && state.errorMessage != null -> EmptyState(
                Icons.Outlined.WifiOff, "没拿到录像", state.errorMessage,
                action = { AmberButton("重试", onClick = { scope.launch { ReplayLibrary.refresh() } }, icon = null) },
                modifier = Modifier.padding(padding),
            )
            state.groups.isEmpty() -> EmptyState(
                Icons.Outlined.VideoLibrary, "最近没有录像", "比赛结束后一两个小时，网友才会陆续上传。",
                action = { AmberButton("刷新", onClick = { scope.launch { ReplayLibrary.refresh() } }, icon = null) },
                modifier = Modifier.padding(padding),
            )
            else -> PullToRefreshBox(
                isRefreshing = state.isLoading,
                onRefresh = { scope.launch { ReplayLibrary.refresh() } },
                modifier = Modifier.padding(padding),
            ) {
                val sections = state.groups.groupBy { it.dayText() }
                LazyColumn(Modifier.fillMaxSize(), contentPadding = listContentPadding) {
                    sections.forEach { (title, groups) ->
                        item(key = "h-$title") { GroupTitle(title) }
                        groups.forEachIndexed { index, group ->
                            item(key = group.id) {
                                GroupedCell(index, groups.size, onClick = { onOpenGroup(group) }) {
                                    Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                        ReplayCover(group.videos.firstOrNull()?.coverUrl)
                                        Column(Modifier.padding(start = 12.dp).weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                            Text(group.title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                            Text(group.partsSummary, fontSize = 12.sp, color = Palette.secondaryText, maxLines = 1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    item {
                        Text(
                            "${ReplayDisclaimer.FOOTER} · 查看回看使用说明",
                            fontSize = 13.sp, color = Palette.accent,
                            modifier = Modifier.clickable { readsDisclaimer = true }.padding(horizontal = 32.dp, vertical = 10.dp),
                        )
                        Text(
                            "录像来自微博网友公开上传。上传的人删了视频，这里也就看不了了。",
                            fontSize = 12.sp, color = Palette.tertiaryText,
                            modifier = Modifier.padding(horizontal = 32.dp, vertical = 4.dp),
                        )
                    }
                }
            }
        }
    }
}

/** Every upload of one game: whole game first, then halves and quarters. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReplayGroupScreen(group: ReplayGroup, onBack: () -> Unit) {
    val context = LocalContext.current
    val app = context.applicationContext as com.leeguoo.jrkan.JrkanApp
    val opening by ReplayLauncher.openingId.collectAsState()
    val error by ReplayLauncher.error.collectAsState()
    LaunchedEffect(Unit) { ReplayLauncher.error.value = null }
    Scaffold(
        containerColor = Palette.background,
        topBar = {
            TopAppBar(
                title = { Text(group.title) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Palette.background),
            )
        },
    ) { padding ->
        LazyColumn(Modifier.padding(padding).fillMaxSize(), contentPadding = listContentPadding) {
            item { GroupTitle("${group.dayText()} · ${group.videos.size} 个视频") }
            error?.let { message ->
                item { Text(message, color = Palette.live, fontSize = 14.sp, modifier = Modifier.padding(horizontal = 32.dp, vertical = 6.dp)) }
            }
            group.videos.forEachIndexed { index, video ->
                item(key = video.id) {
                    GroupedCell(index, group.videos.size, onClick = {
                        if (opening == null) ReplayLauncher.play(context, group.videos, index, null, app.preferences, app.scope)
                    }) { ReplayVideoRow(video, isOpening = opening == video.id) }
                }
            }
            item {
                Text("同一场比赛常有好几个人上传，挑一个能播的就行。播放时可以换成其他视频；看到一半退出，下次从原处接着播。",
                    fontSize = 12.sp, color = Palette.tertiaryText, modifier = Modifier.padding(horizontal = 32.dp, vertical = 8.dp))
            }
        }
    }
}

/**
 * Opens a replay in the live player (PlayerSession), so it gets the same
 * furniture: picture in picture, 数据, fill. Resolve first, present second.
 */
object ReplayLauncher {
    val openingId = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    val error = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    private var job: kotlinx.coroutines.Job? = null

    fun play(
        context: android.content.Context, videos: List<ReplayVideo>, index: Int, fixture: LiveMatch?,
        preferences: com.leeguoo.jrkan.state.Preferences, scope: kotlinx.coroutines.CoroutineScope,
    ) {
        if (index !in videos.indices) return
        job?.cancel()
        error.value = null
        openingId.value = videos[index].id
        job = scope.launch {
            try {
                val found = fixture ?: com.leeguoo.jrkan.data.ReplayFixture.nbaMatch(videos)
                val model = com.leeguoo.jrkan.state.MatchPlaybackModel.replay(videos, found, preferences, scope)
                model.startPlayback(index)
                val state = kotlinx.coroutines.withTimeoutOrNull(30_000) {
                    model.state.first { it.playback != null || it.errorMessage != null }
                }
                if (state?.playback != null) PlayerSession.show(context, model)
                else error.value = state?.errorMessage ?: "这个视频暂时打不开。"
            } finally {
                openingId.value = null
            }
        }
    }
}

@Composable
private fun ReplayVideoRow(video: ReplayVideo, isOpening: Boolean = false, downloadFixture: LiveMatch? = null, downloads: Boolean = true) {
    Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
        Box {
            ReplayCover(video.coverUrl)
            Text(
                ReplayVideo.durationText(video.durationSeconds), fontSize = 10.sp, color = Color.White, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.align(Alignment.BottomEnd).padding(3.dp)
                    .background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(3.dp)).padding(horizontal = 4.dp),
            )
        }
        Column(Modifier.padding(start = 12.dp).weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(video.part.label, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Text(video.title, fontSize = 12.sp, color = Palette.secondaryText, maxLines = 2, overflow = TextOverflow.Ellipsis)
            val resume = com.leeguoo.jrkan.data.ReplayResume.positionMs(video.id)
            Text("${video.author} · ${postedFormat.format(Date(video.postedAt))}" +
                (resume?.let { " · 看到 ${ReplayVideo.durationText(it / 1000.0)}" } ?: ""),
                fontSize = 11.sp, color = Palette.tertiaryText, maxLines = 1)
        }
        if (isOpening) CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp, color = Palette.accent)
        else if (downloads) ReplayDownloadButton(video, downloadFixture)
        else Icon(Icons.Filled.PlayCircle, "播放", tint = Palette.accent, modifier = Modifier.size(28.dp))
    }
}

@Composable
private fun ReplayCover(url: String?) {
    val shape = RoundedCornerShape(6.dp)
    Box(Modifier.width(96.dp).size(96.dp, 54.dp).clip(shape).background(Palette.fill)) {
        if (url != null) {
            AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
    }
}

/** 回放 on a match screen once the match is over (MatchReplaySection in ReplaysScreen.swift). */
@Composable
fun MatchReplaySection(match: LiveMatch) {
    if (!MatchReplays.isEligible(match)) return
    val replays = remember(match.id) { MatchReplays(match) }
    val state by replays.state.collectAsState()
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val app = context.applicationContext as com.leeguoo.jrkan.JrkanApp
    val opening by ReplayLauncher.openingId.collectAsState()
    val launchError by ReplayLauncher.error.collectAsState()
    var showsAll by remember { mutableStateOf(false) }
    var pendingIndex by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(match.id) { if (replays.state.value == MatchReplays.State.Idle) replays.load() }

    Column(
        Modifier.padding(horizontal = 16.dp, vertical = 8.dp).fillMaxWidth()
            .clip(RoundedCornerShape(10.dp)).background(Palette.cell).padding(vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text("回放", fontSize = 17.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 16.dp))
        when (val s = state) {
            MatchReplays.State.Idle, MatchReplays.State.Loading -> Row(
                Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Palette.accent)
                Text("正在找录像…", color = Palette.secondaryText)
            }
            is MatchReplays.State.Failed -> Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(s.message, color = Palette.secondaryText, fontSize = 14.sp, modifier = Modifier.weight(1f))
                TextButton(onClick = { scope.launch { replays.load() } }) { Text("重试", color = Palette.accent) }
            }
            is MatchReplays.State.Loaded -> if (s.videos.isEmpty()) {
                Text("还没有人上传这场的录像，过一两个小时再来看看。", color = Palette.secondaryText, fontSize = 14.sp,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
            } else {
                val shown = if (showsAll) s.videos else s.videos.take(4)
                launchError?.let { Text(it, color = Palette.live, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 16.dp)) }
                shown.forEachIndexed { index, video ->
                    Box(Modifier.clickable {
                        if (!ReplayDisclaimer.isAccepted(context)) { pendingIndex = index; return@clickable }
                        // The match itself is the fixture: it orders the teams and feeds 数据.
                        if (opening == null) ReplayLauncher.play(context, s.videos, index, match, app.preferences, app.scope)
                    }) { ReplayVideoRow(video, isOpening = opening == video.id, downloadFixture = match) }
                }
                if (s.videos.size > shown.size) {
                    TextButton(onClick = { showsAll = true }, modifier = Modifier.padding(horizontal = 4.dp)) {
                        Text("全部 ${s.videos.size} 个视频", color = Palette.accent)
                    }
                }
            }
        }
    }
    pendingIndex?.let { index ->
        val videos = (state as? MatchReplays.State.Loaded)?.videos.orEmpty()
        ReplayDisclaimerDialog(onAgree = {
            ReplayDisclaimer.accept(context)
            pendingIndex = null
            ReplayLauncher.play(context, videos, index, match, app.preferences, app.scope)
        }, onDismiss = { pendingIndex = null })
    }
}

private val postedFormat = SimpleDateFormat("M月d日 HH:mm", Locale.CHINA)


/** Download state for one upload: download (asks for the quality, with sizes), progress, or done. */
@Composable
fun ReplayDownloadButton(video: ReplayVideo, fixture: LiveMatch?) {
    val items by com.leeguoo.jrkan.state.ReplayDownloads.items.collectAsState()
    val live by com.leeguoo.jrkan.state.ReplayDownloads.liveBytes.collectAsState()
    val item = items.firstOrNull { it.id == video.id }
    val scope = rememberCoroutineScope()
    var choices by remember { mutableStateOf<List<com.leeguoo.jrkan.data.ReplayStream>?>(null) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val downloads = com.leeguoo.jrkan.state.ReplayDownloads
    val phase = item?.phase
    Box(Modifier.size(40.dp).clickable {
        when (phase) {
            com.leeguoo.jrkan.state.ReplayDownload.Phase.Downloading, com.leeguoo.jrkan.state.ReplayDownload.Phase.Queued -> downloads.pause(video.id)
            com.leeguoo.jrkan.state.ReplayDownload.Phase.Paused, com.leeguoo.jrkan.state.ReplayDownload.Phase.Failed -> downloads.resume(video.id)
            com.leeguoo.jrkan.state.ReplayDownload.Phase.Finished -> Unit
            null -> scope.launch {
                loading = true
                try {
                    val streams = com.leeguoo.jrkan.data.ReplayCache.usableStreams(video.id)
                        ?: ReplayParsing.streams(ReplayLibrary.client.status(video.id)).also { com.leeguoo.jrkan.data.ReplayCache.storeStreams(it, video.id) }
                    if (streams.isEmpty()) error = "这个视频已经看不了了。" else choices = streams.sortedBy { it.height }
                } catch (e: Exception) {
                    error = e.userMessage()
                } finally { loading = false }
            }
        }
    }, contentAlignment = Alignment.Center) {
        live.size // recompose on progress
        when (phase) {
            com.leeguoo.jrkan.state.ReplayDownload.Phase.Finished -> Icon(Icons.Filled.CheckCircle, "已下载", tint = Palette.ok, modifier = Modifier.size(26.dp))
            com.leeguoo.jrkan.state.ReplayDownload.Phase.Downloading, com.leeguoo.jrkan.state.ReplayDownload.Phase.Queued ->
                CircularProgressIndicator(progress = { downloads.progress(video.id) ?: 0.02f }, modifier = Modifier.size(24.dp), strokeWidth = 3.dp, color = Palette.accent)
            com.leeguoo.jrkan.state.ReplayDownload.Phase.Paused -> Icon(Icons.Filled.PauseCircle, "已暂停", tint = Palette.secondaryText, modifier = Modifier.size(26.dp))
            com.leeguoo.jrkan.state.ReplayDownload.Phase.Failed -> Icon(Icons.Filled.ErrorOutline, "下载失败", tint = Palette.live, modifier = Modifier.size(26.dp))
            null -> if (loading) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Palette.accent)
                else Icon(Icons.Filled.Download, "下载", tint = Palette.accent, modifier = Modifier.size(26.dp))
        }
    }
    choices?.let { streams ->
        AlertDialog(
            onDismissRequest = { choices = null },
            title = { Text("下载到本机") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("${ReplayDisclaimer.FOOTER}。视频只保存在本应用里，下载时可以切到别的应用。", fontSize = 13.sp, color = Palette.secondaryText)
                    streams.forEach { stream ->
                        TextButton(onClick = { choices = null; downloads.download(video, stream, fixture) }) {
                            Text("${stream.qualityLabel} · ${stream.size?.let { android.text.format.Formatter.formatShortFileSize(androidx.compose.ui.platform.LocalContext.current, it) } ?: "大小未知"}", color = Palette.accent)
                        }
                    }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { choices = null }) { Text("取消") } },
            containerColor = Palette.cell,
        )
    }
    error?.let { message ->
        AlertDialog(onDismissRequest = { error = null }, title = { Text("没法下载") }, text = { Text(message) },
            confirmButton = { TextButton(onClick = { error = null }) { Text("好") } }, containerColor = Palette.cell)
    }
}

/** 已下载: downloads and their progress; a finished one plays offline. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReplayDownloadsScreen(onBack: () -> Unit) {
    val items by com.leeguoo.jrkan.state.ReplayDownloads.items.collectAsState()
    val live by com.leeguoo.jrkan.state.ReplayDownloads.liveBytes.collectAsState()
    val context = LocalContext.current
    val app = context.applicationContext as com.leeguoo.jrkan.JrkanApp
    val error by ReplayLauncher.error.collectAsState()
    var confirmDelete by remember { mutableStateOf<com.leeguoo.jrkan.state.ReplayDownload?>(null) }
    fun size(bytes: Long) = android.text.format.Formatter.formatShortFileSize(context, bytes)
    Scaffold(
        containerColor = Palette.background,
        topBar = {
            TopAppBar(
                title = { Text("已下载") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Palette.background),
            )
        },
    ) { padding ->
        if (items.isEmpty()) {
            EmptyState(Icons.Filled.Download, "还没有下载", "在回看里点视频右边的下载按钮。", modifier = Modifier.padding(padding))
            return@Scaffold
        }
        LazyColumn(Modifier.padding(padding).fillMaxSize(), contentPadding = listContentPadding) {
            error?.let { message -> item { Text(message, color = Palette.live, fontSize = 14.sp, modifier = Modifier.padding(horizontal = 32.dp, vertical = 6.dp)) } }
            items.forEachIndexed { index, item ->
                item(key = item.id) {
                    GroupedCell(index, items.size, onClick = {
                        if (item.phase == com.leeguoo.jrkan.state.ReplayDownload.Phase.Finished) {
                            ReplayLauncher.play(context, listOf(item.video), 0, item.fixture, app.preferences, app.scope)
                        }
                    }, onLongClick = { confirmDelete = item }) {
                        Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            ReplayCover(item.video.coverUrl)
                            Column(Modifier.padding(start = 12.dp).weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(item.video.displayTitle, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                val total = item.totalBytes ?: item.expectedBytes
                                val done = live[item.id] ?: item.receivedBytes
                                val sizes = total?.let { "${size(done)} / ${size(it)}" } ?: size(done)
                                val status = when (item.phase) {
                                    com.leeguoo.jrkan.state.ReplayDownload.Phase.Finished -> "已下载 · ${size(item.receivedBytes)} · 点一下离线播放"
                                    com.leeguoo.jrkan.state.ReplayDownload.Phase.Downloading -> "正在下载 · $sizes"
                                    com.leeguoo.jrkan.state.ReplayDownload.Phase.Queued -> "排队中 · $sizes"
                                    com.leeguoo.jrkan.state.ReplayDownload.Phase.Paused -> "已暂停 · $sizes${item.message?.let { " · $it" } ?: ""}"
                                    com.leeguoo.jrkan.state.ReplayDownload.Phase.Failed -> "${item.message ?: "下载失败"} · 点右边重试"
                                }
                                Text(status, fontSize = 12.sp, maxLines = 2,
                                    color = if (item.phase == com.leeguoo.jrkan.state.ReplayDownload.Phase.Failed) Palette.live else Palette.tertiaryText)
                            }
                            ReplayDownloadButton(item.video, item.fixture)
                        }
                    }
                }
            }
            item {
                Text("共占用 ${size(items.sumOf { com.leeguoo.jrkan.state.ReplayDownloads.fileSize(it.id) })}。${ReplayDisclaimer.FOOTER}；视频只保存在本应用里，研究学习完请及时删除。长按可以删除。",
                    fontSize = 12.sp, color = Palette.tertiaryText, modifier = Modifier.padding(horizontal = 32.dp, vertical = 8.dp))
            }
        }
    }
    confirmDelete?.let { item ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null },
            title = { Text("删除下载？") },
            text = { Text("「${item.video.displayTitle}」会从本机删除。") },
            confirmButton = { TextButton(onClick = { com.leeguoo.jrkan.state.ReplayDownloads.delete(item.id); confirmDelete = null }) { Text("删除", color = Palette.live) } },
            dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("取消") } },
            containerColor = Palette.cell,
        )
    }
}
