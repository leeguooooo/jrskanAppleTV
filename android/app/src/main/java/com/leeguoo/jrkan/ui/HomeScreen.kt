package com.leeguoo.jrkan.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.selection.selectable
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SportsBasketball
import androidx.compose.material.icons.filled.SportsScore
import androidx.compose.material.icons.filled.SportsSoccer
import androidx.compose.material3.Icon
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.SportFilter
import com.leeguoo.jrkan.state.MatchListModel

/**
 * The phone home: a tab per sport plus search, like the iPhone app. The tab
 * is `model.filter`, so a pick survives a relaunch; 热门 / 关注 / 最近观看
 * refine the 比赛 tab and keep it selected.
 */
@Composable
fun HomeScreen(model: MatchListModel, onOpenMatch: (LiveMatch, Boolean) -> Unit, onOpenSettings: () -> Unit) {
    val filter by model.filter.collectAsState()
    var searching by rememberSaveable { mutableStateOf(false) }
    val selectedSport = if (filter in SportFilter.tabs) filter else SportFilter.All

    Scaffold(
        containerColor = Palette.background,
        bottomBar = {
            ScoreTabBar {
                for (sport in SportFilter.tabs) {
                    ScoreTab(
                        selected = !searching && selectedSport == sport,
                        icon = tabIcon(sport),
                        label = if (sport == SportFilter.All) "比赛" else sport.title,
                    ) {
                        searching = false
                        // Re-picking 比赛 while a refinement is on keeps the refinement.
                        if (sport != SportFilter.All || filter in SportFilter.tabs) model.setFilter(sport)
                    }
                }
                ScoreTab(selected = searching, icon = Icons.Filled.Search, label = "搜索") { searching = true }
            }
        },
    ) { padding ->
        val inner = Modifier.padding(bottom = padding.calculateBottomPadding())
        if (searching) {
            SearchScreen(model, onOpenMatch = { onOpenMatch(it, false) }, modifier = inner)
        } else {
            MatchListScreen(model, selectedSport, onOpenMatch, onOpenSettings, modifier = inner)
        }
    }
}

/** The tab bar as one 8dp card: amber tint and wash on the selected tab, no pill indicator. */
@Composable
private fun ScoreTabBar(content: @Composable RowScope.() -> Unit) {
    Box(
        Modifier
            .fillMaxWidth()
            .background(Palette.background)
            .windowInsetsPadding(WindowInsets.navigationBars)
            .padding(start = 16.dp, end = 16.dp, top = 6.dp, bottom = 10.dp),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .height(62.dp)
                .clip(ScoreShape)
                .background(Palette.cell)
                .border(1.dp, Color(0xFF3A3229), ScoreShape)
                .padding(horizontal = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            content = content,
        )
    }
}

@Composable
private fun RowScope.ScoreTab(selected: Boolean, icon: ImageVector, label: String, onClick: () -> Unit) {
    val tint = if (selected) Palette.accent else Palette.secondaryText
    Column(
        Modifier
            .weight(1f)
            .height(50.dp)
            .clip(ScoreShape)
            .background(if (selected) Palette.accent.copy(alpha = 0.12f) else Color.Transparent)
            .selectable(selected = selected, role = Role.Tab, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(21.dp))
        Spacer(Modifier.height(3.dp))
        Text(label, color = tint, fontSize = 10.sp, fontWeight = FontWeight.Bold, maxLines = 1)
    }
}

internal fun tabIcon(sport: SportFilter): ImageVector = when (sport) {
    SportFilter.Basketball -> Icons.Filled.SportsBasketball
    SportFilter.Badminton -> ShuttlecockIcon
    SportFilter.Football -> Icons.Filled.SportsSoccer
    else -> Icons.Filled.SportsScore
}
