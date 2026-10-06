package com.leeguoo.jrkan.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SearchOff
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.state.MatchListModel

/** The search tab: today's competitions until something is typed, then fixtures across every sport. */
@Composable
fun SearchScreen(model: MatchListModel, onOpenMatch: (LiveMatch) -> Unit, modifier: Modifier = Modifier) {
    val state by model.state.collectAsState()
    val query by model.searchText.collectAsState()
    val favorites by model.preferences.favoriteTeams.collectAsState()
    val focus = LocalFocusManager.current
    val now = rememberNow()

    Column(modifier.fillMaxSize().statusBarsPadding()) {
        Text(
            "搜索",
            fontSize = 34.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(start = 20.dp, top = 16.dp, bottom = 12.dp),
        )
        TextField(
            value = query,
            onValueChange = model::setSearchText,
            placeholder = { Text("球队或联赛") },
            leadingIcon = { Icon(Icons.Filled.Search, null) },
            trailingIcon = {
                if (query.isNotEmpty()) IconButton(onClick = { model.setSearchText("") }) { Icon(Icons.Filled.Close, "清除") }
            },
            singleLine = true,
            shape = RoundedCornerShape(14.dp),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { focus.clearFocus() }),
            colors = TextFieldDefaults.colors(
                focusedContainerColor = Palette.cell,
                unfocusedContainerColor = Palette.cell,
                focusedIndicatorColor = Color.Transparent,
                unfocusedIndicatorColor = Color.Transparent,
            ),
            modifier = Modifier.fillMaxWidth().padding(horizontal = Grouped.gutter),
        )

        if (query.isEmpty()) {
            val leagues = model.leagueNames(state.matches)
            LazyColumn(contentPadding = listContentPadding) {
                item { SectionHeader("今天的联赛") }
                itemsIndexed(leagues, key = { _, league -> league }) { index, league ->
                    GroupedCell(index, leagues.size, onClick = { model.setSearchText(league) }) {
                        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(league, fontSize = 16.sp, modifier = Modifier.weight(1f))
                            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Palette.tertiaryText)
                        }
                    }
                }
            }
        } else {
            val results = model.visibleMatches(state.matches, query)
            if (results.isEmpty()) {
                EmptyState(Icons.Filled.SearchOff, "没有“$query”的结果", "换个关键词试试，比如联赛名或球队简称。")
            } else {
                LazyColumn(contentPadding = listContentPadding) {
                    item { SectionHeader("比赛", results.size) }
                    itemsIndexed(results, key = { _, m -> m.id }) { index, match ->
                        MatchCell(match, index, results.size, now, favorites, model.preferences) {
                            focus.clearFocus()
                            onOpenMatch(it)
                        }
                    }
                }
            }
        }
    }
}
