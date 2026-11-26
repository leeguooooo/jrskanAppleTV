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
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 回看 (ReplaysScreen.swift): recent recordings fans post on Weibo, a row per game. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReplaysScreen(onOpenGroup: (ReplayGroup) -> Unit, onBack: () -> Unit) {
    val state by ReplayLibrary.state.collectAsState()
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { ReplayLibrary.refreshIfStale() }

    Scaffold(
        containerColor = Palette.background,
        topBar = {
            TopAppBar(
                title = { Text("回看") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
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
                            "录像来自微博网友上传，打开时现取播放地址。上传的人删了视频，这里也就看不了了。",
                            fontSize = 12.sp, color = Palette.tertiaryText,
                            modifier = Modifier.padding(horizontal = 32.dp, vertical = 8.dp),
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
    var playing by remember { mutableStateOf<ReplayVideo?>(null) }
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
            group.videos.forEachIndexed { index, video ->
                item(key = video.id) {
                    GroupedCell(index, group.videos.size, onClick = { playing = video }) { ReplayVideoRow(video) }
                }
            }
            item {
                Text("同一场比赛常有好几个人上传，挑一个能播的就行。", fontSize = 12.sp, color = Palette.tertiaryText,
                    modifier = Modifier.padding(horizontal = 32.dp, vertical = 8.dp))
            }
        }
    }
    playing?.let { ReplayPlayer(it, onClose = { playing = null }) }
}

@Composable
private fun ReplayVideoRow(video: ReplayVideo) {
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
            Text("${video.author} · ${postedFormat.format(Date(video.postedAt))}", fontSize = 11.sp, color = Palette.tertiaryText, maxLines = 1)
        }
        Icon(Icons.Filled.PlayCircle, "播放", tint = Palette.accent, modifier = Modifier.size(28.dp))
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
    var playing by remember { mutableStateOf<ReplayVideo?>(null) }
    var showsAll by remember { mutableStateOf(false) }
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
                shown.forEach { video -> Box(Modifier.clickable { playing = video }) { ReplayVideoRow(video) } }
                if (s.videos.size > shown.size) {
                    TextButton(onClick = { showsAll = true }, modifier = Modifier.padding(horizontal = 4.dp)) {
                        Text("全部 ${s.videos.size} 个视频", color = Palette.accent)
                    }
                }
            }
        }
    }
    playing?.let { ReplayPlayer(it, onClose = { playing = null }) }
}

/**
 * Full-screen player for one recording, separate from the live PlayerSession.
 * Weibo's links expire after about an hour and a game runs two to three, so a
 * playback error (or resuming near expiry) fetches a fresh link and seeks back.
 */
@Composable
fun ReplayPlayer(video: ReplayVideo, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var error by remember(video.id) { mutableStateOf<String?>(null) }
    var stream by remember(video.id) { mutableStateOf<ReplayStream?>(null) }
    val refreshes = remember(video.id) { mutableListOf<Long>() }
    val player = remember(video.id) {
        PlayerSession.pauseForOtherPlayback()
        ExoPlayer.Builder(context).build()
    }

    fun load(resumeAt: Long?) {
        val now = System.currentTimeMillis()
        refreshes.removeAll { now - it > 120_000 }
        refreshes += now
        if (refreshes.size > 3) { error = "这个视频一直播放失败，可能已被删除。"; return }
        scope.launch {
            try {
                val best = ReplayParsing.streams(ReplayLibrary.client.status(video.id)).firstOrNull()
                if (best == null) { error = "这个视频已经看不了了（可能被删除或设为仅粉丝可见）。"; return@launch }
                stream = best
                player.setMediaItem(MediaItem.fromUri(best.url))
                player.prepare()
                if (resumeAt != null && resumeAt > 1000) player.seekTo(resumeAt)
                player.playWhenReady = true
                error = null
            } catch (e: Exception) {
                error = "拿不到播放地址：${e.userMessage()}"
            }
        }
    }

    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onPlayerError(e: PlaybackException) = load(player.currentPosition)
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                val expires = stream?.expiresAt ?: return
                if (isPlaying && expires - System.currentTimeMillis() < 120_000) load(player.currentPosition)
            }
        }
        player.addListener(listener)
        load(null)
        onDispose {
            player.removeListener(listener)
            player.release()
        }
    }

    // MainActivity turns this into landscape with the system bars hidden, the
    // same chrome as the live player's 全屏, and undoes it on close.
    DisposableEffect(Unit) {
        ReplayLibrary.playerOpen.value = true
        onDispose { ReplayLibrary.playerOpen.value = false }
    }
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
            Text(
                "${video.matchup?.let { "${it.left} vs ${it.right}" } ?: video.title} · ${video.part.label}" + (stream?.let { " · ${it.qualityLabel}" } ?: ""),
                color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        error?.let { message ->
            Column(
                Modifier.align(Alignment.Center).padding(24.dp).background(Color.Black.copy(alpha = 0.75f), RoundedCornerShape(12.dp)).padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(message, color = Color.White)
                AmberButton("关闭", onClick = onClose, icon = null)
            }
        }
    }
}

private val postedFormat = SimpleDateFormat("M月d日 HH:mm", Locale.CHINA)
