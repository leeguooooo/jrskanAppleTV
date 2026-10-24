package com.leeguoo.jrkan.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.leeguoo.jrkan.data.SportsSnapshot
import com.leeguoo.jrkan.data.SportsStatComparison
import com.leeguoo.jrkan.data.SportsTable
import com.leeguoo.jrkan.state.MatchInsightsModel
import com.leeguoo.jrkan.state.MatchPlaybackModel
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** Same content hierarchy and source semantics as SportsInsightsViews.swift. */
object SportsColors {
    val left = Color(0xFF3D87FF)
    val right = Color(0xFFFFA64A)
    val canvas = Color(0xFF050509)
    val line = Color.White.copy(alpha = 0.09f)
    val surface = Color.White.copy(alpha = 0.055f)
}

/** Exactly one consumer: the route until playback opens, then PlayerScreen. */
@Composable
fun SportsInsightsBinding(model: MatchPlaybackModel, enabled: Boolean = true) {
    val playback by model.state.collectAsState()
    val owner = LocalLifecycleOwner.current
    val channels = model.resolvedChannels
    val key = playback.channels?.map { it.id }
    LaunchedEffect(model, key, enabled, owner) {
        if (enabled) owner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            model.insights.watch(model.match, channels)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SportsStatsDialog(model: MatchInsightsModel, onClose: () -> Unit) {
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(
            containerColor = SportsColors.canvas,
            topBar = {
                TopAppBar(title = { Text("比赛数据", fontSize = 17.sp, fontWeight = FontWeight.SemiBold) },
                    navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "关闭比赛数据") } },
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = SportsColors.canvas))
            },
        ) { padding -> SportsStatsContent(model, Modifier.padding(padding)) }
    }
}

@Composable
fun SportsStatsContent(model: MatchInsightsModel, modifier: Modifier = Modifier, initialPlayers: Boolean = false) {
    val state by model.state.collectAsState()
    var players by rememberSaveable { androidx.compose.runtime.mutableStateOf(initialPlayers) }
    var team by rememberSaveable { mutableIntStateOf(0) }
    val snapshot = state.snapshot
    val configuration = LocalConfiguration.current
    val compact = configuration.screenHeightDp < 480 && configuration.screenWidthDp > configuration.screenHeightDp
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Column(Modifier.widthIn(max = 1200.dp), verticalArrangement = Arrangement.spacedBy(if (compact) 16.dp else 24.dp)) {
            if (snapshot == null) {
                Box(Modifier.fillMaxWidth().height(200.dp), contentAlignment = Alignment.Center) {
                    Text(state.status, color = Palette.secondaryText, fontSize = 15.sp, textAlign = TextAlign.Center)
                }
            } else {
                Scoreboard(snapshot, compact)
                Row(Modifier.fillMaxWidth().borderBottom()) {
                    listOf("本场概况", "技术统计").forEachIndexed { index, label ->
                        val active = players == (index == 1)
                        TextButton(onClick = { players = index == 1 }, modifier = Modifier.weight(1f)
                            .semantics { selected = active }.testTag(if (index == 0) "sports_overview" else "sports_players")) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                Text(label, color = if (active) SportsColors.left else Palette.secondaryText,
                                    fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                                Spacer(Modifier.height(12.dp))
                                Box(Modifier.width(56.dp).height(3.dp).clip(CircleShape).background(if (active) SportsColors.left else Color.Transparent))
                            }
                        }
                    }
                }
                if (!players) {
                    snapshot.periodTable?.let { PeriodScores(it) }
                    snapshot.comparisonTable?.let { TeamComparison(it, snapshot) }
                    if (snapshot.periodTable == null && snapshot.comparisonTable == null) NoStatistics()
                } else {
                    val tables = snapshot.playerTables
                    if (tables.isEmpty()) NoStatistics() else {
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            tables.forEachIndexed { index, table ->
                                TextButton(onClick = { team = index }, modifier = Modifier
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(if (team == index) SportsColors.left.copy(alpha = 0.2f) else SportsColors.surface)
                                    .border(1.dp, if (team == index) SportsColors.left else Color.Transparent, RoundedCornerShape(8.dp))
                                    .semantics { selected = team == index }) {
                                    Text(table.title.substringBefore(" · "), color = Color.White, fontWeight = FontWeight.SemiBold)
                                }
                            }
                        }
                        FrozenPlayerTable(tables[team.coerceAtMost(tables.lastIndex)])
                        Text("球员姓名固定，左右滚动查看其余统计", color = Palette.secondaryText, fontSize = 12.sp)
                    }
                }
                val time = DateTimeFormatter.ofPattern("HH:mm:ss").withZone(ZoneId.systemDefault()).format(Instant.ofEpochMilli(snapshot.updatedAt))
                Text("腾讯体育  $time 更新", color = Palette.secondaryText, fontSize = 12.sp)
                if (state.status.isNotEmpty()) Text(state.status, color = Palette.secondaryText, fontSize = 12.sp)
            }
        }
    }
}

@Composable
private fun Scoreboard(snapshot: SportsSnapshot, compact: Boolean) {
    val scores = snapshot.score.split(":").map(String::trim)
    if (compact) {
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(SportsColors.surface).padding(10.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TeamCrest(snapshot.leftBadge, snapshot.left, 26.dp)
            Text(snapshot.left, color = Color.White, fontSize = 14.sp)
            Text(scores.getOrElse(0) { "—" }, color = SportsColors.left, fontSize = 26.sp, fontWeight = FontWeight.Bold)
            Text(snapshot.period, Modifier.weight(1f), color = Palette.secondaryText, fontSize = 12.sp, textAlign = TextAlign.Center)
            Text(scores.getOrElse(1) { "—" }, color = SportsColors.right, fontSize = 26.sp, fontWeight = FontWeight.Bold)
            Text(snapshot.right, color = Color.White, fontSize = 14.sp)
            TeamCrest(snapshot.rightBadge, snapshot.right, 26.dp)
        }
        return
    }
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(SportsColors.surface).padding(horizontal = 14.dp, vertical = 22.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Text(snapshot.period, color = SportsColors.left, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ScoreTeam(snapshot.left, snapshot.leftBadge, SportsColors.left, Modifier.weight(1f))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(scores.getOrElse(0) { "—" }, color = Color.White, fontSize = 36.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                Text(":", color = Palette.tertiaryText, fontSize = 36.sp)
                Text(scores.getOrElse(1) { "—" }, color = Color.White, fontSize = 36.sp, fontWeight = FontWeight.Bold, maxLines = 1)
            }
            ScoreTeam(snapshot.right, snapshot.rightBadge, SportsColors.right, Modifier.weight(1f))
        }
    }
}

@Composable
private fun ScoreTeam(name: String, badge: String?, tint: Color, modifier: Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TeamCrest(badge, name, 42.dp)
        Text(name, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, maxLines = 2)
        Box(Modifier.size(24.dp, 3.dp).clip(CircleShape).background(tint))
    }
}

@Composable
private fun Heading(title: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
        Box(Modifier.size(3.dp, 16.dp).background(SportsColors.left))
        Text(title, color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun PeriodScores(table: SportsTable) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Heading("分节得分")
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val cell = maxOf(34.dp, (maxWidth - 80.dp) / (table.headers.size - 1).coerceAtLeast(1))
            Column(Modifier.horizontalScroll(rememberScrollState())) {
                PeriodRow(table.headers, cell, true)
                table.rows.forEach { PeriodRow(it, cell, false) }
            }
        }
    }
}

@Composable
private fun PeriodRow(values: List<String>, width: Dp, header: Boolean) {
    Row(Modifier.background(if (header) Color.White.copy(alpha = 0.04f) else Color.Transparent).borderBottom()) {
        values.forEachIndexed { index, value ->
            Box(Modifier.width(if (index == 0) 80.dp else width).height(44.dp)
                .background(if (index == values.lastIndex) SportsColors.left.copy(alpha = 0.08f) else Color.Transparent),
                contentAlignment = if (index == 0) Alignment.CenterStart else Alignment.Center) {
                Text(value, color = if (header) Palette.secondaryText else Color.White, fontSize = 14.sp,
                    fontWeight = if (header || index == values.lastIndex) FontWeight.SemiBold else FontWeight.Normal)
            }
        }
    }
}

@Composable
private fun TeamComparison(table: SportsTable, snapshot: SportsSnapshot) {
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Heading("球队对比")
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("●  ${snapshot.left}", color = SportsColors.left, fontSize = 12.sp)
            Text("●  ${snapshot.right}", color = SportsColors.right, fontSize = 12.sp)
        }
        table.rows.forEach { row ->
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(row.getOrElse(1) { "—" }, Modifier.weight(1f), color = SportsColors.left, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                    Text(row.firstOrNull().orEmpty(), color = Palette.secondaryText, fontSize = 12.sp, textAlign = TextAlign.Center)
                    Text(row.getOrElse(2) { "—" }, Modifier.weight(1f), color = SportsColors.right, fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold, textAlign = TextAlign.End)
                }
                SportsStatComparison.from(row)?.let { metric ->
                    BoxWithConstraints(Modifier.fillMaxWidth().height(5.dp)) {
                        val barWidth = (maxWidth - 3.dp).coerceAtLeast(0.dp)
                        Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                            Box(Modifier.width(barWidth * metric.leftShare).height(5.dp).clip(CircleShape).background(SportsColors.left))
                            Box(Modifier.weight(1f).height(5.dp).clip(CircleShape).background(SportsColors.right))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FrozenPlayerTable(table: SportsTable) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).testTag("sports_player_table")) {
        Column(Modifier.width(124.dp).background(SportsColors.canvas)) {
            PlayerCell(table.headers.firstOrNull().orEmpty(), 0, true, false)
            table.rows.forEachIndexed { index, row ->
                Box(Modifier.background(if (index % 2 == 0) Color.Transparent else Color.White.copy(alpha = 0.025f))) {
                    PlayerCell(row.firstOrNull().orEmpty(), 0, false, row.firstOrNull() == "统计")
                }
            }
        }
        Column(Modifier.weight(1f).horizontalScroll(rememberScrollState())) {
            Row { table.headers.drop(1).forEachIndexed { index, text -> PlayerCell(text, index + 1, true, false) } }
            table.rows.forEachIndexed { index, row ->
                Row(Modifier.background(if (index % 2 == 0) Color.Transparent else Color.White.copy(alpha = 0.025f))) {
                    row.drop(1).forEachIndexed { column, text -> PlayerCell(text, column + 1, false, row.firstOrNull() == "统计") }
                }
            }
        }
    }
}

@Composable
private fun PlayerCell(text: String, column: Int, header: Boolean, total: Boolean) {
    Box(Modifier.width(if (column == 0) 124.dp else 60.dp).height(44.dp)
        .background(if (header || total) Color.White.copy(alpha = 0.05f) else Color.Transparent)
        .borderBottom().padding(start = if (column == 0) 8.dp else 0.dp),
        contentAlignment = if (column == 0) Alignment.CenterStart else Alignment.Center) {
        Text(text, color = if (header) Palette.secondaryText else if (column == 2) SportsColors.left else Color.White,
            fontSize = 14.sp, fontWeight = if (header || total || column == 2) FontWeight.SemiBold else FontWeight.Normal,
            maxLines = if (column == 0) 2 else 1)
    }
}

@Composable
private fun NoStatistics() { Text("腾讯体育暂无本场技术统计", color = Palette.secondaryText, fontSize = 15.sp, modifier = Modifier.padding(vertical = 32.dp)) }

private fun Modifier.borderBottom(): Modifier = drawBehind {
    drawLine(SportsColors.line, start = androidx.compose.ui.geometry.Offset(0f, size.height),
        end = androidx.compose.ui.geometry.Offset(size.width, size.height), strokeWidth = 1f)
}
