package com.leeguoo.jrkan.ui

import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import com.leeguoo.jrkan.data.AppConfig
import com.leeguoo.jrkan.state.AppConfigStore
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.FilterListOff
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.SportsScore
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.MatchSchedule
import com.leeguoo.jrkan.data.SportFilter
import com.leeguoo.jrkan.state.MatchListModel
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Ticks every 30 s so countdowns and live minutes move without a refresh. */
@Composable
fun rememberNow(): Long = produceState(System.currentTimeMillis()) {
    while (true) {
        delay(30_000)
        value = System.currentTimeMillis()
    }
}.value

/** One sport's list inside the tab bar. Mirrors CompactMatchListScreen.swift. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MatchListScreen(
    model: MatchListModel,
    sport: SportFilter,
    onOpenMatch: (LiveMatch, Boolean) -> Unit,
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by model.state.collectAsState()
    val filter by model.filter.collectAsState()
    val favorites by model.preferences.favoriteTeams.collectAsState()
    val recent by model.preferences.recentWatches.collectAsState()
    val now = rememberNow()
    val appConfig by AppConfigStore.config.collectAsState()
    val member by AppConfigStore.isMember.collectAsState()
    val uriHandler = LocalUriHandler.current

    val title = when {
        filter == SportFilter.All -> "今日比赛"
        sport == SportFilter.All -> filter.title
        else -> sport.title
    }
    val shown = remember(state.matches, filter, favorites, recent) { model.filteredMatches(state.matches, filter, favorites) }
    val sections = remember(state.matches, filter, favorites, recent, now) { model.sections(state.matches, filter, favorites) }

    val liveCount = remember(shown, now) { shown.count { MatchSchedule.status(it, now).isLive } }
    // The first live match leads as a hero card and is left out of the rows below.
    val hero = remember(sections, filter) {
        if (filter == SportFilter.Recent) null
        else sections.firstOrNull { it.status is com.leeguoo.jrkan.data.MatchStatus.Live }?.matches?.firstOrNull()
    }

    Scaffold(
        modifier = modifier,
        containerColor = Color.Transparent,
        topBar = {
            ListHeader(title, liveCount) {
                if (sport == SportFilter.All) RefinementMenu(model, filter)
                IconButton(onClick = onOpenSettings) { Icon(Icons.Outlined.Settings, "设置", tint = Palette.secondaryText) }
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            when {
                state.isLoading && state.matches.isEmpty() -> LazyColumn {
                    item { SectionHeader("正在载入") }
                    items(8) { GroupedCell(it, 8) { PlaceholderRow() } }
                }
                state.errorMessage != null && state.matches.isEmpty() -> EmptyState(
                    Icons.Filled.WifiOff, "暂时无法载入比赛", state.errorMessage,
                    action = { AmberButton("重试", onClick = { model.refresh() }, icon = null) },
                )
                else -> PullToRefreshBox(isRefreshing = state.isLoading, onRefresh = { model.refresh() }) {
                    LazyColumn(Modifier.fillMaxSize(), contentPadding = listContentPadding) {
                        item(key = "subtitle") {
                            Text(
                                subtitle(state, shown, now),
                                fontSize = 13.sp,
                                color = Palette.secondaryText,
                                modifier = Modifier.padding(horizontal = 20.dp).padding(bottom = 4.dp),
                            )
                        }
                        val banner = if (sport == SportFilter.All) appConfig.slot("home_banner", member) else null
                        if (banner != null) {
                            item(key = "banner") {
                                Column(Modifier.padding(top = 12.dp)) {
                                    GroupedCell(0, 1, onClick = banner.link?.let { link -> { uriHandler.openUri(link) } }) { ConfigBanner(banner) }
                                }
                            }
                        }
                        val resume = if (sport == SportFilter.All && filter == SportFilter.All) model.continueMatch(state.matches) else null
                        if (resume != null) {
                            item(key = "resume") {
                                Column(Modifier.padding(top = 12.dp)) {
                                    GroupedCell(0, 1, onClick = { onOpenMatch(resume, true) }) { ContinueWatchingRow(resume) }
                                }
                            }
                        }
                        val error = state.errorMessage
                        if (error != null) {
                            item(key = "error") {
                                Column(Modifier.padding(top = 12.dp)) {
                                    GroupedCell(0, 1) {
                                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                                            Icon(Icons.Filled.Warning, null, tint = Palette.flame, modifier = Modifier.size(20.dp))
                                            Text(
                                                "赛程刷新失败，下面是上次读取的赛程。$error",
                                                fontSize = 13.sp,
                                                modifier = Modifier.weight(1f).padding(horizontal = 12.dp),
                                            )
                                            TextButton(onClick = { model.refresh() }) { Text("重试") }
                                        }
                                    }
                                }
                            }
                        }
                        if (hero != null) {
                            item(key = "hero-${hero.id}") {
                                Column(Modifier.padding(top = 14.dp)) { LiveHeroCard(hero, now) { onOpenMatch(it, false) } }
                            }
                        }
                        for (section in sections) {
                            val rows = if (hero == null) section.matches else section.matches.filter { it.id != hero.id }
                            if (rows.isEmpty()) continue
                            val live = section.status is com.leeguoo.jrkan.data.MatchStatus.Live
                            matchSection(
                                "s${section.id}", headingTitle(section.title), rows, now, favorites, model.preferences,
                                hint = if (live) "点比赛直接开播" else null,
                            ) { onOpenMatch(it, false) }
                        }
                    }
                    if (shown.isEmpty()) {
                        if (filter == SportFilter.Followed) {
                            EmptyState(Icons.Outlined.StarOutline, "关注的球队今天没有比赛", "长按任意比赛可以关注球队。")
                        } else {
                            EmptyState(
                                if (sport == SportFilter.All) Icons.Filled.SportsScore else tabIcon(sport),
                                if (sport == SportFilter.All) "今天没有比赛" else "今天没有${sport.title}比赛",
                                "下拉刷新看看最新赛程。",
                            )
                        }
                    }
                }
            }
        }
    }
    LaunchedEffect(Unit) { model.loadIfNeeded() }
}

/** The mockup's wording for the upcoming group; the model keeps its own title. */
private fun headingTitle(title: String): String = title

/** Small caps date line, serif title, live count badge; refinement and settings at the right. */
@Composable
private fun ListHeader(title: String, liveCount: Int, actions: @Composable () -> Unit) {
    val date = remember { SimpleDateFormat("MM.dd EEE", Locale.US).format(Date()).uppercase(Locale.US) }
    Column(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).padding(start = 20.dp, end = 8.dp, top = 6.dp, bottom = 6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("LEEGUOO SPORTS · $date", style = chakraStyle(12.sp, FontWeight.Bold, Palette.secondaryText), letterSpacing = 1.6.sp,
                modifier = Modifier.weight(1f), maxLines = 1)
            actions()
        }
        Row(Modifier.padding(end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            HeadingText(title, 34.sp, Modifier.weight(1f))
            if (liveCount > 0) LiveBadge("● $liveCount 场直播", size = 13.sp)
        }
    }
}

/** Counts follow the tab, and a score-feed problem replaces the timestamp. */
private fun subtitle(state: MatchListModel.State, shown: List<LiveMatch>, now: Long): String {
    val live = shown.count { MatchSchedule.status(it, now).isLive }
    val parts = mutableListOf<String>()
    if (live > 0) parts += "$live 场进行中"
    parts += "共 ${shown.size} 场"
    val notice = state.scoreNotice
    val updated = state.scoresUpdatedAt ?: state.lastUpdated
    if (notice != null) {
        parts += notice
    } else if (updated != null) {
        // The feed goes quiet when nothing is on; only call it stale when it should be moving.
        val stale = live > 0 && state.scoresUpdatedAt != null && now - updated > 120_000
        parts += if (stale) "比分数据较旧" else "${SimpleDateFormat("HH:mm", Locale.CHINA).format(Date(updated))} 更新"
    }
    return parts.joinToString(" · ")
}

/** 热门 / 关注 / 最近观看 narrow 全部 rather than being tabs of their own. */
@Composable
private fun RefinementMenu(model: MatchListModel, filter: SportFilter) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(
                if (filter == SportFilter.All) Icons.Filled.FilterList else Icons.Filled.FilterListOff,
                "筛选",
                tint = if (filter == SportFilter.All) Palette.secondaryText else Palette.accent,
            )
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            val options = listOf(SportFilter.All) + model.availableFilters().filter { it !in SportFilter.tabs }
            for (option in options) {
                DropdownMenuItem(
                    text = {
                        Text(if (option == SportFilter.All) "全部比赛" else "${option.title}  ${model.categoryCount(option)}")
                    },
                    leadingIcon = { RadioButton(selected = option == filter, onClick = null) },
                    onClick = { model.setFilter(option); open = false },
                )
            }
        }
    }
}

@Composable
private fun ContinueWatchingRow(match: LiveMatch) {
    Row(
        Modifier.fillMaxWidth().padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Filled.PlayCircle, null, tint = Palette.accent, modifier = Modifier.size(34.dp))
        Column {
            Text("继续观看", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            Text("${match.homeTeam} vs ${match.awayTeam}", fontSize = 15.sp, color = Palette.secondaryText, maxLines = 1)
        }
    }
}

/** The `home_banner` ad slot (ConfigBanner.swift), labelled 推广 so it never passes for a match. */
@Composable
private fun ConfigBanner(slot: AppConfig.Slot) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    "推广", fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = Palette.secondaryText,
                    modifier = Modifier.border(0.5.dp, Palette.separator, RoundedCornerShape(4.dp)).padding(horizontal = 5.dp, vertical = 1.dp),
                )
                Text(slot.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (slot.detail.isNotEmpty()) {
                Text(slot.detail, fontSize = 12.sp, color = Palette.secondaryText, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        if (slot.link != null) Icon(Icons.AutoMirrored.Filled.OpenInNew, null, tint = Palette.tertiaryText, modifier = Modifier.size(18.dp))
    }
}
