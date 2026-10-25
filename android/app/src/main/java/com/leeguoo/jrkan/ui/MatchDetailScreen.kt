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
import androidx.compose.runtime.setValue
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.ui.Alignment
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
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
    val playerModel by com.leeguoo.jrkan.player.PlayerSession.model.collectAsState()
    var showsChannels by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
    var showsStatistics by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
    val now = rememberNow()
    val match = listState.matches.firstOrNull { it.id == playback.match.id } ?: playback.match.copy(providerState = null)
    if (playerModel !== playback) SportsInsightsBinding(playback)
    LaunchedEffect(match.id) { playback.openMatch(autoplay) }
    val context = androidx.compose.ui.platform.LocalContext.current
    val insights by playback.insights.state.collectAsState()
    Box(Modifier.fillMaxSize().scoreboardGround()) {
        // Team-colour wash behind the scoreboard, as in Detail.dc.html.
        Box(
            Modifier.fillMaxWidth().height(420.dp)
                .background(Brush.radialGradient(listOf(Color(0x801F4FA3), Color.Transparent), center = Offset(80f, 80f), radius = 900f))
                .background(Brush.radialGradient(listOf(Color(0x73C8102E), Color.Transparent), center = Offset(Float.POSITIVE_INFINITY, 80f), radius = 900f)),
        )
        LazyColumn(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars), contentPadding = listContentPadding) {
            item {
                Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    GlassIconButton(Icons.AutoMirrored.Filled.ArrowBack, "返回", onBack)
                    Text(match.league, Modifier.weight(1f), fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                        textAlign = TextAlign.Center, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    GlassIconButton(Icons.Filled.BarChart, "比赛数据", { showsStatistics = true }, enabled = state.channels != null)
                }
            }
            item { Hero(match, now, favorites, listModel.preferences, listState.scoresUpdatedAt) }
            state.errorMessage?.let { message -> item { Notice(message, Icons.Filled.Warning, Palette.live) } }
            item {
                Column(Modifier.padding(horizontal = 16.dp, vertical = 18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    val playingHere = playerModel === playback && state.playback != null
                    if (state.channels == null || state.resolvingIndex != null) {
                        Row(Modifier.height(52.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Palette.accent)
                            val source = state.resolvingIndex?.let { playback.resolvedChannels.getOrNull(it) }
                            Text(if (state.channels == null) "正在寻找中文高清…" else "正在打开${source?.name ?: "直播"}…", color = Palette.secondaryText)
                        }
                    } else if (match.sources.isEmpty()) {
                        Text("这场比赛还没有直播线路，开赛前后再试。", color = Palette.secondaryText)
                    } else {
                        AmberButton(
                            when {
                                playingHere -> "继续观看"
                                state.errorMessage != null -> "重新播放"
                                else -> "播放比赛"
                            },
                            onClick = {
                                if (playingHere) com.leeguoo.jrkan.player.PlayerSession.show(context, playback)
                                else playback.startSuggestedPlayback()
                            },
                            modifier = Modifier.fillMaxWidth(),
                            height = 52.dp,
                        )
                    }
                    LineCaption(playback, state, showsChannels) { showsChannels = !showsChannels }
                }
            }
            if (showsChannels) {
                state.channelNotice?.let { item { Notice(it, Icons.Filled.Info, Palette.secondaryText) } }
                val channels = playback.resolvedChannels
                val remembered = playback.rememberedChannel
                channels.forEachIndexed { index, source ->
                    item(key = "c$index-${source.id}") {
                        GroupedCell(index, channels.size, onClick = {
                            if (state.resolvingIndex == null) playback.startManualPlayback(index)
                        }, dividerInset = 70.dp) {
                            ChannelRow(index + 1, source.name, playback.subtitle(source, index),
                                state.resolvingIndex == index, remembered?.id == source.id)
                        }
                    }
                }
            }
            val snapshot = insights.snapshot
            if (snapshot != null) {
                snapshot.periodTable?.let { table -> item(key = "periods") { DetailCard { PeriodScoresCompact(table, snapshot) } } }
                snapshot.comparisonTable?.let { table -> item(key = "team") { DetailCard { TeamBars(table, snapshot) } } }
            }
        }
    }
    if (showsStatistics) SportsStatsDialog(playback.insights) { showsStatistics = false }
}

@Composable
private fun DetailCard(content: @Composable () -> Unit) {
    Column(
        Modifier.padding(horizontal = 16.dp, vertical = 6.dp).fillMaxWidth().clip(ScoreShape)
            .background(Palette.cell).border(1.dp, Palette.separator, ScoreShape).padding(horizontal = 16.dp, vertical = 12.dp),
    ) { content() }
}

/** "✓ 自动选线 · <channel> · 失效自动换" on the left, "手动切换线路 ›" (collapsed by default) on the right. */
@Composable
private fun LineCaption(playback: MatchPlaybackModel, state: MatchPlaybackModel.State, expanded: Boolean, onToggle: () -> Unit) {
    val playing = state.playback?.let { playback.resolvedChannels.getOrNull(it.index) }
    val channel = playing ?: playback.suggestedChannel
    val manual = state.choseManually && playing != null
    Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        if (channel != null) {
            Icon(if (manual) Icons.Filled.PanTool else Icons.Filled.Check, null,
                tint = if (manual) Palette.accent else Palette.ok, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(6.dp))
            val tail = if (!manual && playback.automaticFallbackEnabled) " · 失效自动换" else ""
            Text("${if (manual) "手动选线" else "自动选线"} · ${channel.name}$tail", fontSize = 13.sp, color = Palette.secondaryText,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        } else Spacer(Modifier.weight(1f))
        Row(
            Modifier.clip(ScoreShape).clickable(enabled = state.channels != null && state.resolvingIndex == null, onClick = onToggle)
                .padding(horizontal = 4.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(if (expanded) "收起手动线路" else "手动切换线路", fontSize = 13.sp, color = Palette.secondaryText)
            Icon(if (expanded) Icons.Filled.ExpandLess else Icons.AutoMirrored.Filled.KeyboardArrowRight, null,
                tint = Palette.secondaryText, modifier = Modifier.size(16.dp))
        }
    }
}

@Composable
private fun GlassIconButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit, enabled: Boolean = true) {
    Box(
        Modifier.size(40.dp).clip(ScoreShape).background(Color(0x1AFFECD2)).border(0.5.dp, Color(0x24FFECD2), ScoreShape)
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, label, tint = if (enabled) Palette.primaryText else Palette.tertiaryText, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun Hero(match: LiveMatch, now: Long, favorites: Set<String>, preferences: Preferences, scoresUpdatedAt: Long?) {
    val status = MatchSchedule.status(match, now)
    val shown = MatchSchedule.displayTime(match.time, now)
    val score = splitScore(match.scoreText)
    Column(Modifier.fillMaxWidth().padding(top = 14.dp, start = 16.dp, end = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Row(verticalAlignment = Alignment.Top) {
            TeamBlock(match.homeTeam, match.homeLogoUrl, match.homeTeam in favorites) { preferences.toggleFavorite(match.homeTeam) }
            Column(Modifier.padding(top = 10.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (score != null) LedScore(score.first, score.second, 70.sp)
                else Text("VS", style = chakraStyle(30.sp, FontWeight.Bold, Palette.tertiaryText))
                StatusLine(status, match.isHot, if (shown.day.isEmpty()) shown.clock else "${shown.day} ${shown.clock}")
                if (MatchSchedule.viewerIsOffFeedTime(nowMillis = now)) {
                    Text("北京 ${match.time}", fontSize = 11.sp, color = Palette.tertiaryText)
                }
            }
            TeamBlock(match.awayTeam, match.awayLogoUrl, match.awayTeam in favorites) { preferences.toggleFavorite(match.awayTeam) }
        }
        Statistics(match)
        Spacer(Modifier.height(8.dp))
        Text(
            if (match.providerState != null && scoresUpdatedAt != null) "比分随直播自动更新" else "本场实时数据暂不可用",
            fontSize = 12.sp, color = Palette.tertiaryText,
        )
    }
}

@Composable
private fun StatusLine(status: MatchStatus, hot: Boolean, kickoff: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (hot) Text("热门", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Palette.flame)
        when (status) {
            is MatchStatus.Live -> Row(
                Modifier.clip(ScoreShape).background(Palette.live).padding(horizontal = 10.dp, vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                LiveDot(6.dp, Color.White)
                Text(status.label, style = chakraStyle(12.sp, FontWeight.Bold, Color.White), maxLines = 1)
            }
            is MatchStatus.Upcoming -> Text(
                if (status.startsInMinutes <= 90) "${status.startsInMinutes} 分钟后开赛" else kickoff,
                style = chakraStyle(13.sp, FontWeight.Bold, if (status.startsInMinutes <= 90) Palette.accent else Palette.secondaryText),
            )
            MatchStatus.Finished -> Text("已结束", fontSize = 13.sp, color = Palette.secondaryText)
            MatchStatus.Scheduled -> Text(kickoff, style = chakraStyle(13.sp, FontWeight.Bold, Palette.secondaryText))
            is MatchStatus.Interrupted -> Text(status.label, fontSize = 13.sp, color = Palette.secondaryText)
            MatchStatus.Unknown -> Text(kickoff, style = chakraStyle(13.sp, FontWeight.Bold, Palette.secondaryText))
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.TeamBlock(name: String, logo: String?, following: Boolean, onToggle: () -> Unit) {
    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        TeamCrest(logo, name, 76.dp)
        Text(name, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, maxLines = 2)
        Row(
            Modifier
                .clip(ScoreShape)
                .background(if (following) Palette.accent.copy(alpha = 0.14f) else Color(0x1AFFECD2))
                .clickable(onClick = onToggle)
                .padding(horizontal = 10.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(
                if (following) Icons.Filled.Star else Icons.Outlined.StarOutline, null,
                tint = if (following) Palette.accent else Palette.primaryText, modifier = Modifier.size(13.dp),
            )
            Text(if (following) "已关注" else "关注", fontSize = 12.sp, fontWeight = FontWeight.SemiBold,
                color = if (following) Palette.accent else Palette.primaryText)
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
        Box(Modifier.size(40.dp).clip(ScoreShape).background(Palette.accent.copy(alpha = 0.14f)), contentAlignment = Alignment.Center) {
            if (busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = Palette.accent)
            else Text("$number", style = chakraStyle(17.sp, FontWeight.Bold, Palette.accent))
        }
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(name, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (lastWatched) {
                    Text(
                        "上次观看", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Palette.accent,
                        modifier = Modifier.clip(ScoreShape).background(Palette.accent.copy(alpha = 0.14f)).padding(horizontal = 7.dp, vertical = 2.dp),
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
            .clip(ScoreShape)
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
