package com.leeguoo.jrkan.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.windowInsetsPadding
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
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

/** Same content hierarchy and source semantics as SportsInsightsViews.swift, in the scoreboard palette. */
object SportsColors {
    val left = Palette.home
    val right = Palette.away
    val canvas = Palette.background
    val line = Color(0x0FFFECD2)
    val surface = Palette.cell
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

/** The full-page statistics (detail dialog and the parity harness). */
@Composable
fun SportsStatsContent(model: MatchInsightsModel, modifier: Modifier = Modifier, initialPlayers: Boolean = false) {
    val state by model.state.collectAsState()
    var players by rememberSaveable { mutableStateOf(initialPlayers) }
    val snapshot = state.snapshot
    val configuration = LocalConfiguration.current
    val compact = configuration.screenHeightDp < 480 && configuration.screenWidthDp > configuration.screenHeightDp
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Column(Modifier.widthIn(max = 1200.dp), verticalArrangement = Arrangement.spacedBy(if (compact) 14.dp else 20.dp)) {
            if (snapshot == null) {
                Box(Modifier.fillMaxWidth().height(200.dp), contentAlignment = Alignment.Center) {
                    Text(state.status, color = Palette.secondaryText, fontSize = 15.sp, textAlign = TextAlign.Center)
                }
            } else {
                Scoreboard(snapshot)
                snapshot.scoreSourceName?.takeIf { it != snapshot.sourceName }?.let {
                    Text("比分来源：$it", color = Palette.secondaryText, fontSize = 12.sp)
                }
                UnderlineTabs(listOf("本场概况", "技术统计"), if (players) 1 else 0, tags = listOf("sports_overview", "sports_players")) { players = it == 1 }
                if (!players) {
                    snapshot.periodTable?.let { PeriodScoresCompact(it, snapshot); TableSource(it) }
                    snapshot.comparisonTable?.let { TeamBars(it, snapshot); TableSource(it) }
                    if (snapshot.periodTable == null && snapshot.comparisonTable == null) NoStatistics()
                } else {
                    PlayersSection(snapshot)
                }
                Footer(snapshot, state.status)
            }
        }
    }
}

/** Which page a stats tab shows. */
enum class StatsTab(val title: String) {
    Overview("赛况"), Players("球员数据"), PlayersShort("球员"), Team("球队对比"), TeamShort("球队"), Periods("分节"),
}

/**
 * Tabbed statistics for the player: the landscape side panel (球员 / 球队 / 分节)
 * and the upright watch page (赛况 / 球员数据 / 球队对比). No scoreboard of its
 * own — the player already shows the score next to it.
 */
@Composable
fun SportsStatsTabs(model: MatchInsightsModel, tabs: List<StatsTab>, modifier: Modifier = Modifier, initial: Int = 0) {
    val state by model.state.collectAsState()
    var selected by rememberSaveable { mutableIntStateOf(initial) }
    val snapshot = state.snapshot
    Column(modifier) {
        UnderlineTabs(tabs.map { it.title }, selected, Modifier.padding(horizontal = 14.dp)) { selected = it }
        Column(Modifier.weight(1f, fill = true).verticalScroll(rememberScrollState()).padding(top = 10.dp)
            .windowInsetsPadding(WindowInsets.navigationBars.only(WindowInsetsSides.Bottom))) {
            if (snapshot == null) {
                Box(Modifier.fillMaxWidth().height(160.dp), contentAlignment = Alignment.Center) {
                    Text(state.status.ifEmpty { "正在载入本场数据…" }, color = Palette.secondaryText, fontSize = 14.sp, textAlign = TextAlign.Center)
                }
            } else {
                Column(Modifier.padding(horizontal = 14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    when (tabs.getOrElse(selected) { tabs.first() }) {
                        StatsTab.Players, StatsTab.PlayersShort -> PlayersSection(snapshot)
                        StatsTab.Team, StatsTab.TeamShort -> snapshot.comparisonTable?.let { TeamBars(it, snapshot); TableSource(it) } ?: NoStatistics()
                        StatsTab.Periods -> snapshot.periodTable?.let { PeriodScoresCompact(it, snapshot); TableSource(it) } ?: NoStatistics()
                        StatsTab.Overview -> {
                            snapshot.periodTable?.let { PeriodScoresCompact(it, snapshot) }
                            snapshot.comparisonTable?.let { TeamBars(it, snapshot, limit = 5) }
                            if (snapshot.periodTable == null && snapshot.comparisonTable == null) NoStatistics()
                        }
                    }
                    Footer(snapshot, state.status)
                }
            }
        }
    }
}

@Composable
private fun UnderlineTabs(labels: List<String>, selected: Int, modifier: Modifier = Modifier, tags: List<String>? = null, onSelect: (Int) -> Unit) {
    Row(modifier.fillMaxWidth().borderBottom(), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
        labels.forEachIndexed { index, label ->
            val active = index == selected
            Column(
                Modifier.width(IntrinsicSize.Max).clickable { onSelect(index) }.semantics { this.selected = active }
                    .let { m -> tags?.getOrNull(index)?.let { m.testTag(it) } ?: m }
                    .padding(top = 12.dp),
            ) {
                Text(label, color = if (active) Palette.primaryText else Palette.secondaryText, fontSize = 15.sp,
                    fontWeight = if (active) FontWeight.Bold else FontWeight.Normal, maxLines = 1)
                Spacer(Modifier.height(9.dp))
                Box(Modifier.height(2.dp).fillMaxWidth().background(if (active) Palette.primaryText else Color.Transparent))
            }
        }
    }
}

@Composable
private fun PlayersSection(snapshot: SportsSnapshot) {
    var team by rememberSaveable { mutableIntStateOf(0) }
    val tables = snapshot.playerTables
    if (tables.isEmpty()) { NoStatistics(); return }
    val badges = listOf(snapshot.leftBadge, snapshot.rightBadge)
    // Team switch: a two-up segmented control, 8dp corners.
    Row(Modifier.fillMaxWidth().clip(ScoreShape).background(Color(0x12FFECD2)).padding(3.dp)) {
        tables.forEachIndexed { index, table ->
            val name = table.title.substringBefore(" · ")
            val active = team == index
            Row(
                Modifier.weight(1f).height(30.dp).clip(RoundedCornerShape(6.dp))
                    .background(if (active) Color(0x24FFECD2) else Color.Transparent)
                    .clickable { team = index }.semantics { selected = active },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center,
            ) {
                val badge = badges.getOrNull(index).takeIf { tables.size == 2 }
                if (badge != null) { TeamCrest(badge, name, 16.dp); Spacer(Modifier.width(6.dp)) }
                Text(name, color = if (active) Palette.primaryText else Palette.secondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
    val table = tables[team.coerceAtMost(tables.lastIndex)]
    FrozenPlayerTable(table)
    Text("表格可左右滑动 · 球员名固定在左侧", color = Palette.tertiaryText, fontSize = 11.sp)
    TableSource(table)
}

@Composable
private fun Footer(snapshot: SportsSnapshot, status: String) {
    val time = DateTimeFormatter.ofPattern("HH:mm:ss").withZone(ZoneId.systemDefault()).format(Instant.ofEpochMilli(snapshot.updatedAt))
    Text("${snapshot.sourceName} · $time 更新", color = Palette.tertiaryText, style = chakraStyle(11.sp, FontWeight.SemiBold, Palette.tertiaryText))
    if (status.isNotEmpty()) Text(status, color = Palette.secondaryText, fontSize = 12.sp)
}

@Composable
private fun Scoreboard(snapshot: SportsSnapshot) {
    val scores = snapshot.score.split(":").map(String::trim)
    Row(Modifier.fillMaxWidth().clip(ScoreShape).background(Palette.cell).border(1.dp, Palette.separator, ScoreShape).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TeamCrest(snapshot.leftBadge, snapshot.left, 30.dp)
            Text(snapshot.left, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            LedScore(scores.getOrElse(0) { "—" }, scores.getOrElse(1) { "—" }, 34.sp, colonPadding = 4.dp)
            Text(snapshot.period, style = chakraStyle(11.sp, FontWeight.Bold, Palette.live), maxLines = 1)
        }
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
            Text(snapshot.right, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            TeamCrest(snapshot.rightBadge, snapshot.right, 30.dp)
        }
    }
}

/** Period scores as a compact grid: team, one column per period, bold total. */
@Composable
fun PeriodScoresCompact(table: SportsTable, snapshot: SportsSnapshot) {
    val totals = table.rows.map { it.lastOrNull()?.trim()?.toIntOrNull() }
    val best = totals.filterNotNull().maxOrNull()
    val badges = listOf(snapshot.leftBadge, snapshot.rightBadge)
    Column(Modifier.fillMaxWidth()) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val periods = (table.headers.size - 1).coerceAtLeast(1)
            val cell = ((maxWidth - 100.dp) / periods).coerceIn(30.dp, 48.dp)
            Column(Modifier.horizontalScroll(rememberScrollState())) {
                Row(Modifier.height(32.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("", Modifier.width(100.dp))
                    table.headers.drop(1).forEachIndexed { index, header ->
                        val total = index == table.headers.size - 2 && header.contains("总")
                        Text(header.removePrefix("第").removeSuffix("节"), Modifier.width(cell), textAlign = if (total) TextAlign.End else TextAlign.Center,
                            style = chakraStyle(12.sp, FontWeight.SemiBold, Palette.secondaryText), maxLines = 1)
                    }
                }
                table.rows.forEachIndexed { rowIndex, row ->
                    Row(Modifier.height(38.dp).borderTop(), verticalAlignment = Alignment.CenterVertically) {
                        Row(Modifier.width(100.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (table.rows.size == 2) TeamCrest(badges.getOrNull(rowIndex), row.firstOrNull().orEmpty(), 20.dp)
                            Text(row.firstOrNull().orEmpty(), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        row.drop(1).forEachIndexed { index, value ->
                            val last = index == row.size - 2
                            val leading = last && totals.getOrNull(rowIndex) != null && totals[rowIndex] == best
                            Text(value, Modifier.width(cell), textAlign = if (last) TextAlign.End else TextAlign.Center, maxLines = 1,
                                style = chakraStyle(15.sp, if (last) FontWeight.Bold else FontWeight.SemiBold,
                                    when { value.trim() == "—" || value.isBlank() -> Color(0xFF4A443C); last && leading -> Palette.primaryText
                                        last -> Palette.secondaryText; else -> Color(0xFFCFC5B5) }))
                        }
                    }
                }
            }
        }
    }
}

/** Team comparison: values either side, label centred, home blue / away amber bars from the centre. */
@Composable
fun TeamBars(table: SportsTable, snapshot: SportsSnapshot, limit: Int = Int.MAX_VALUE) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(13.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("球队数据", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Text("● ${snapshot.left}", color = Palette.home, fontSize = 11.sp)
            Spacer(Modifier.width(10.dp))
            Text("● ${snapshot.right}", color = Palette.away, fontSize = 11.sp)
        }
        table.rows.take(limit).forEach { row ->
            val metric = SportsStatComparison.from(row)
            val leftLeads = metric != null && metric.left >= metric.right
            val rightLeads = metric != null && metric.right >= metric.left
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(row.getOrElse(1) { "—" }, Modifier.width(72.dp), maxLines = 1,
                        style = chakraStyle(14.sp, if (leftLeads) FontWeight.Bold else FontWeight.SemiBold, if (leftLeads) Palette.primaryText else Palette.secondaryText))
                    Text(row.firstOrNull().orEmpty(), Modifier.weight(1f), color = Palette.secondaryText, fontSize = 12.sp, textAlign = TextAlign.Center, maxLines = 1)
                    Text(row.getOrElse(2) { "—" }, Modifier.width(72.dp), textAlign = TextAlign.End, maxLines = 1,
                        style = chakraStyle(14.sp, if (rightLeads) FontWeight.Bold else FontWeight.SemiBold, if (rightLeads) Palette.primaryText else Palette.secondaryText))
                }
                if (metric != null) {
                    val max = maxOf(metric.left, metric.right).takeIf { it > 0 } ?: 1.0
                    Row(Modifier.fillMaxWidth().height(4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Box(Modifier.weight(1f).fillMaxSize().clip(RoundedCornerShape(2.dp)).background(Color(0x0FFFECD2)), contentAlignment = Alignment.CenterEnd) {
                            Box(Modifier.fillMaxWidth((metric.left / max).toFloat()).fillMaxSize().clip(RoundedCornerShape(2.dp)).background(Palette.home))
                        }
                        Box(Modifier.weight(1f).fillMaxSize().clip(RoundedCornerShape(2.dp)).background(Color(0x0FFFECD2)), contentAlignment = Alignment.CenterStart) {
                            Box(Modifier.fillMaxWidth((metric.right / max).toFloat()).fillMaxSize().clip(RoundedCornerShape(2.dp)).background(Palette.away))
                        }
                    }
                }
            }
        }
    }
}

/** Player table: the name column stays put, the stat columns scroll sideways; top scorer in amber. */
@Composable
private fun FrozenPlayerTable(table: SportsTable) {
    val pointsColumn = table.headers.indexOf("得分").takeIf { it > 0 } ?: 2
    val bodyRows = table.rows.filter { it.firstOrNull() != "统计" }
    val topPoints = bodyRows.mapNotNull { it.getOrNull(pointsColumn)?.trim()?.toIntOrNull() }.maxOrNull()
    // One width per column, from its longest cell, so headers and values line up.
    val widths = (1 until table.headers.size).map { column ->
        val longest = (listOf(table.headers[column]) + table.rows.map { it.getOrElse(column) { "" } }).maxOf { it.length }
        if (longest > 4) 58.dp else 44.dp
    }
    Row(Modifier.fillMaxWidth().testTag("sports_player_table")) {
        Column(Modifier.width(104.dp).drawBehind {
            drawRect(Brush.horizontalGradient(listOf(Color(0x66000000), Color.Transparent), startX = size.width, endX = size.width + 10.dp.toPx()),
                topLeft = Offset(size.width, 0f), size = androidx.compose.ui.geometry.Size(10.dp.toPx(), size.height))
            drawLine(Color(0x1AFFECD2), Offset(size.width, 0f), Offset(size.width, size.height), 1f)
        }) {
            NameCell(table.headers.firstOrNull().orEmpty(), header = true, total = false)
            table.rows.forEach { row -> NameCell(row.firstOrNull().orEmpty(), header = false, total = row.firstOrNull() == "统计") }
        }
        Column(Modifier.weight(1f).horizontalScroll(rememberScrollState())) {
            Row { table.headers.drop(1).forEachIndexed { index, text -> StatCell(text, widths.getOrElse(index) { 44.dp }, index + 1 == pointsColumn, header = true, highlight = false, total = false) } }
            table.rows.forEach { row ->
                val total = row.firstOrNull() == "统计"
                Row {
                    row.drop(1).forEachIndexed { index, text ->
                        val column = index + 1
                        val top = !total && column == pointsColumn && topPoints != null && text.trim().toIntOrNull() == topPoints
                        StatCell(text, widths.getOrElse(index) { 44.dp }, column == pointsColumn, header = false, highlight = top, total = total,
                            tone = if (table.headers.getOrNull(column) == "+/-") plusMinusTone(text) else null)
                    }
                }
            }
        }
    }
}

private fun plusMinusTone(text: String): Color? = when {
    text.trim().startsWith("-") -> Color(0xFFFF6961)
    text.trim().startsWith("+") -> Palette.ok
    else -> null
}

@Composable
private fun NameCell(text: String, header: Boolean, total: Boolean) {
    // Names like "7 方硕" keep the number small and dim.
    val number = Regex("^(\\d{1,2})\\s+(.+)$").find(text)
    Row(Modifier.width(104.dp).height(if (header) 30.dp else 38.dp).let { if (header) it else it.borderTop() }.padding(start = 4.dp, end = 6.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        if (number != null) Text(number.groupValues[1], style = chakraStyle(10.sp, FontWeight.SemiBold, Palette.tertiaryText), modifier = Modifier.width(14.dp))
        Text(number?.groupValues?.get(2) ?: text, color = if (header) Palette.secondaryText else Palette.primaryText,
            fontSize = if (header) 11.sp else 13.sp, fontWeight = if (header) FontWeight.Normal else FontWeight.SemiBold,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun StatCell(text: String, width: androidx.compose.ui.unit.Dp, points: Boolean, header: Boolean, highlight: Boolean, total: Boolean, tone: Color? = null) {
    Box(Modifier.width(width).height(if (header) 30.dp else 38.dp).let { if (header) it else it.borderTop() }
        .background(if (total) Color(0x0AFFECD2) else Color.Transparent), contentAlignment = Alignment.CenterEnd) {
        Text(text, maxLines = 1, modifier = Modifier.padding(end = 4.dp), style = chakraStyle(
            if (header) 11.sp else 13.sp,
            if (points && !header) FontWeight.Bold else FontWeight.SemiBold,
            when {
                header -> if (points) Palette.primaryText else Palette.secondaryText
                highlight -> Palette.accent
                tone != null -> tone
                else -> Palette.primaryText
            },
        ))
    }
}

@Composable
private fun NoStatistics() { Text("暂无本场技术统计", color = Palette.secondaryText, fontSize = 14.sp, modifier = Modifier.padding(vertical = 28.dp)) }

private fun Modifier.borderBottom(): Modifier = drawBehind {
    drawLine(SportsColors.line, start = Offset(0f, size.height), end = Offset(size.width, size.height), strokeWidth = 1f)
}

private fun Modifier.borderTop(): Modifier = drawBehind {
    drawLine(SportsColors.line, start = Offset(0f, 0f), end = Offset(size.width, 0f), strokeWidth = 1f)
}

@Composable
private fun TableSource(table: SportsTable) {
    if (table.sourceName.isNotEmpty()) Text("来源：${table.sourceName}", color = Palette.tertiaryText, fontSize = 11.sp)
}
