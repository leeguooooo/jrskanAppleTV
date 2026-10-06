package com.leeguoo.jrkan.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SignalWifiStatusbarConnectedNoInternet4
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.StarOutline
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.MatchSchedule
import com.leeguoo.jrkan.data.MatchStatus
import com.leeguoo.jrkan.state.MatchListModel
import com.leeguoo.jrkan.state.MatchPlaybackModel
import com.leeguoo.jrkan.state.Preferences

/**
 * Match detail: score header, then the channel list. Picking a channel
 * resolves it here and only then opens the player, like the iPhone app.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MatchDetailScreen(
    playback: MatchPlaybackModel,
    listModel: MatchListModel,
    autoplay: Boolean,
    onBack: () -> Unit,
) {
    val listState by listModel.state.collectAsState()
    val state by playback.state.collectAsState()
    val favorites by listModel.preferences.favoriteTeams.collectAsState()
    val autoNext by listModel.preferences.autoNextChannel.collectAsState()
    val now = rememberNow()
    // Live data comes from the list; a match no longer listed shows without it.
    val match = listState.matches.firstOrNull { it.id == playback.match.id } ?: playback.match.copy(providerState = null)

    LaunchedEffect(match.id) {
        playback.loadChannels()
        if (autoplay) playback.startSuggestedPlayback()
    }

    Scaffold(
        containerColor = Palette.background,
        topBar = {
            TopAppBar(
                title = { Text(match.league, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Palette.background),
            )
        },
    ) { padding ->
        LazyColumn(Modifier.padding(padding).fillMaxSize(), contentPadding = listContentPadding) {
            item { Hero(match, now, favorites, listModel.preferences, listState.scoresUpdatedAt) }

            item {
                Row(
                    Modifier.padding(start = 20.dp, end = 20.dp, top = 24.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("选择线路", fontSize = 22.sp, fontWeight = FontWeight.Bold)
                    val count = state.channels?.size ?: 0
                    if (count > 0) Text("  $count 条可用", fontSize = 13.sp, color = Palette.secondaryText)
                    Spacer(Modifier.weight(1f))
                    if (autoNext && playback.resolvedChannels.size > 1) {
                        Text("失效自动换", fontSize = 12.sp, color = Palette.tertiaryText)
                    }
                }
            }

            state.channelNotice?.let { item { Notice(it, Icons.Filled.Info, Palette.secondaryText) } }
            state.notice?.let { item { Notice(it, Icons.Filled.Info, Palette.accent) } }
            state.errorMessage?.let { message ->
                item {
                    Notice(message, Icons.Filled.Warning, Palette.live, playback.retryActionTitle) { playback.retryAfterError() }
                }
            }

            when {
                match.sources.isEmpty() -> item {
                    Box(Modifier.height(260.dp)) {
                        EmptyState(
                            Icons.Filled.SignalWifiStatusbarConnectedNoInternet4,
                            "这场比赛还没有线路",
                            "开赛前后线路才会陆续上线，稍后回来看看。",
                        )
                    }
                }
                state.channels == null -> items(3) { GroupedCell(it, 3) { PlaceholderRow() } }
                else -> {
                    val channels = playback.resolvedChannels
                    val remembered = playback.rememberedChannel
                    channels.forEachIndexed { index, source ->
                        item(key = "c$index-${source.id}") {
                            GroupedCell(
                                index, channels.size,
                                onClick = { if (state.resolvingIndex == null) playback.startPlayback(index) },
                                dividerInset = 70.dp,
                            ) {
                                ChannelRow(
                                    number = index + 1,
                                    name = source.name,
                                    subtitle = playback.subtitle(source, index),
                                    busy = state.resolvingIndex == index,
                                    lastWatched = remembered?.id == source.id,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Hero(match: LiveMatch, now: Long, favorites: Set<String>, preferences: Preferences, scoresUpdatedAt: Long?) {
    val status = MatchSchedule.status(match, now)
    val shown = MatchSchedule.displayTime(match.time, now)
    Column(
        Modifier
            .padding(horizontal = Grouped.gutter)
            .clip(RoundedCornerShape(Grouped.corner))
            .background(Palette.cell)
            .padding(vertical = 20.dp, horizontal = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        StatusLine(status, match.isHot)
        Spacer(Modifier.height(14.dp))
        Row(verticalAlignment = Alignment.Top) {
            TeamBlock(match.homeTeam, match.homeLogoUrl, match.homeTeam in favorites) { preferences.toggleFavorite(match.homeTeam) }
            Column(Modifier.width(104.dp).padding(top = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                val score = match.scoreText
                Text(
                    score?.replace(" - ", " : ") ?: "VS",
                    fontSize = if (score == null) 22.sp else 30.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (score == null) Palette.tertiaryText else Palette.primaryText,
                )
                Text(
                    if (shown.day.isEmpty()) shown.clock else "${shown.day} ${shown.clock}",
                    fontSize = 13.sp, color = Palette.secondaryText,
                )
                if (MatchSchedule.viewerIsOffFeedTime(nowMillis = now)) {
                    Text("北京 ${match.time}", fontSize = 11.sp, color = Palette.tertiaryText)
                }
            }
            TeamBlock(match.awayTeam, match.awayLogoUrl, match.awayTeam in favorites) { preferences.toggleFavorite(match.awayTeam) }
        }
        Statistics(match)
        Spacer(Modifier.height(10.dp))
        Text(
            if (match.providerState != null && scoresUpdatedAt != null) "比分随直播自动更新" else "本场实时数据暂不可用",
            fontSize = 12.sp, color = Palette.tertiaryText,
        )
    }
}

@Composable
private fun StatusLine(status: MatchStatus, hot: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (hot) Text("热门", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Palette.flame)
        when (status) {
            is MatchStatus.Live -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                LiveDot(7.dp)
                Text(status.label, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Palette.live)
            }
            is MatchStatus.Upcoming -> if (status.startsInMinutes <= 90) {
                Text("${status.startsInMinutes} 分钟后开赛", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Palette.accent)
            }
            MatchStatus.Finished -> Text("已结束", fontSize = 14.sp, color = Palette.secondaryText)
            MatchStatus.Scheduled -> Text("未开赛", fontSize = 14.sp, color = Palette.secondaryText)
            is MatchStatus.Interrupted -> Text(status.label, fontSize = 14.sp, color = Palette.secondaryText)
            MatchStatus.Unknown -> Unit
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.TeamBlock(name: String, logo: String?, following: Boolean, onToggle: () -> Unit) {
    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        TeamCrest(logo, name, 60.dp)
        Text(name, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, maxLines = 2)
        Row(
            Modifier
                .clip(CircleShape)
                .border(0.5.dp, if (following) Palette.accent else Palette.separator, CircleShape)
                .clickable(onClick = onToggle)
                .padding(horizontal = 12.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(
                if (following) Icons.Filled.Star else Icons.Outlined.StarOutline, null,
                tint = if (following) Palette.accent else Palette.secondaryText, modifier = Modifier.size(14.dp),
            )
            Text(if (following) "已关注" else "关注", fontSize = 12.sp, color = if (following) Palette.accent else Palette.secondaryText)
        }
    }
}

@Composable
private fun Statistics(match: LiveMatch) {
    val state = match.providerState ?: return
    val stats = buildList {
        state.halftimeText?.let { add("半场" to it) }
        state.cornersText?.let { add("角球" to it) }
        state.basketballSummary?.let { (difference, total) -> add("分差" to "$difference"); add("总分" to "$total") }
    }
    if (stats.isEmpty()) return
    Row(Modifier.padding(top = 16.dp), horizontalArrangement = Arrangement.spacedBy(28.dp)) {
        for ((label, value) in stats) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(label, fontSize = 12.sp, color = Palette.secondaryText)
                Text(value, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
private fun ChannelRow(number: Int, name: String, subtitle: String, busy: Boolean, lastWatched: Boolean) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(Palette.accent.copy(alpha = 0.16f)), contentAlignment = Alignment.Center) {
            if (busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Palette.accent)
            else Text("$number", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Palette.accent)
        }
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(name, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (lastWatched) {
                    Text(
                        "上次观看", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Palette.accent,
                        modifier = Modifier.clip(CircleShape).background(Palette.accent.copy(alpha = 0.14f)).padding(horizontal = 7.dp, vertical = 2.dp),
                    )
                }
            }
            Text(subtitle, fontSize = 13.sp, color = Palette.secondaryText, maxLines = 1)
        }
        Icon(Icons.Filled.PlayArrow, null, tint = if (busy) Palette.tertiaryText else Palette.accent)
    }
}

@Composable
private fun Notice(message: String, icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, action: String? = null, onAction: (() -> Unit)? = null) {
    Row(
        Modifier
            .padding(horizontal = Grouped.gutter, vertical = 4.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(tint.copy(alpha = 0.12f))
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(18.dp))
        Text(message, fontSize = 13.sp, modifier = Modifier.weight(1f))
        if (action != null && onAction != null) TextButton(onClick = onAction) { Text(action, color = tint) }
    }
}
