package com.leeguoo.jrkan.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SportsBasketball
import androidx.compose.material.icons.filled.SportsScore
import androidx.compose.material.icons.filled.SportsSoccer
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
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
            NavigationBar(containerColor = Palette.cell) {
                for (sport in SportFilter.tabs) {
                    NavigationBarItem(
                        selected = !searching && selectedSport == sport,
                        onClick = {
                            searching = false
                            // Re-picking 比赛 while a refinement is on keeps the refinement.
                            if (sport != SportFilter.All || filter in SportFilter.tabs) model.setFilter(sport)
                        },
                        icon = { Icon(tabIcon(sport), null) },
                        label = { Text(if (sport == SportFilter.All) "比赛" else sport.title) },
                        colors = tabColors(),
                    )
                }
                NavigationBarItem(
                    selected = searching,
                    onClick = { searching = true },
                    icon = { Icon(Icons.Filled.Search, null) },
                    label = { Text("搜索") },
                    colors = tabColors(),
                )
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

@Composable
private fun tabColors() = NavigationBarItemDefaults.colors(
    selectedIconColor = Palette.accent,
    selectedTextColor = Palette.accent,
    indicatorColor = Palette.accent.copy(alpha = 0.16f),
    unselectedIconColor = Palette.secondaryText,
    unselectedTextColor = Palette.secondaryText,
)

internal fun tabIcon(sport: SportFilter): ImageVector = when (sport) {
    SportFilter.Basketball -> Icons.Filled.SportsBasketball
    SportFilter.Badminton -> ShuttlecockIcon
    SportFilter.Football -> Icons.Filled.SportsSoccer
    else -> Icons.Filled.SportsScore
}
