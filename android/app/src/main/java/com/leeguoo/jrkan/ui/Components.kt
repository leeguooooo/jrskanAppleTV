package com.leeguoo.jrkan.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.SubcomposeAsyncImage
import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.MatchSchedule
import com.leeguoo.jrkan.data.MatchStatus
import com.leeguoo.jrkan.state.Preferences

/** Grouped-list geometry: the iOS inset-grouped look, built from plain Compose. */
object Grouped {
    val corner = 20.dp
    val gutter = 16.dp

    fun shape(index: Int, count: Int): Shape = when {
        count == 1 -> RoundedCornerShape(corner)
        index == 0 -> RoundedCornerShape(topStart = corner, topEnd = corner)
        index == count - 1 -> RoundedCornerShape(bottomStart = corner, bottomEnd = corner)
        else -> RoundedCornerShape(0.dp)
    }
}

/**
 * One cell of a grouped section. Rows stay separate lazy items (so long lists
 * stay lazy) and only the first and last get rounded corners.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun GroupedCell(
    index: Int,
    count: Int,
    onClick: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
    dividerInset: androidx.compose.ui.unit.Dp = 16.dp,
    content: @Composable () -> Unit,
) {
    Column(
        Modifier
            .padding(horizontal = Grouped.gutter)
            .fillMaxWidth()
            .clip(Grouped.shape(index, count))
            .background(Palette.cell)
            .let {
                if (onClick != null || onLongClick != null) {
                    it.combinedClickable(onClick = { onClick?.invoke() }, onLongClick = onLongClick)
                } else it
            }
    ) {
        content()
        if (index < count - 1) {
            HorizontalDivider(Modifier.padding(start = dividerInset), thickness = 0.5.dp, color = Palette.separator)
        }
    }
}

@Composable
fun SectionHeader(title: String, count: Int? = null, modifier: Modifier = Modifier) {
    Row(
        modifier.padding(start = 20.dp, end = 20.dp, top = 24.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        if (count != null) {
            Text("$count", style = MaterialTheme.typography.titleLarge, color = Palette.tertiaryText)
        }
    }
}

/** Plain pulsing dot; the live label next to it carries the meaning. */
@Composable
fun LiveDot(size: androidx.compose.ui.unit.Dp = 6.dp) {
    val transition = rememberInfiniteTransition(label = "live")
    val alpha by transition.animateFloat(
        initialValue = 1f, targetValue = 0.35f,
        animationSpec = infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "alpha",
    )
    Box(Modifier.size(size).alpha(alpha).clip(CircleShape).background(Palette.live))
}

/** Team logo drawn bare; a monogram disc only when there is no logo. */
@Composable
fun TeamCrest(url: String?, teamName: String, size: androidx.compose.ui.unit.Dp) {
    val monogram = @Composable {
        Box(
            Modifier.size(size).clip(CircleShape).background(Color.White.copy(alpha = 0.08f)),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                teamName.take(1),
                fontSize = (size.value * 0.42f).sp,
                fontWeight = FontWeight.Bold,
                color = Palette.secondaryText,
            )
        }
    }
    if (url.isNullOrBlank()) {
        monogram()
    } else {
        SubcomposeAsyncImage(
            model = url,
            contentDescription = null,
            contentScale = ContentScale.Fit,
            modifier = Modifier.size(size),
            loading = { Box(Modifier.size(size).clip(CircleShape).background(Palette.fill)) },
            error = { monogram() },
        )
    }
}

/**
 * One fixture laid out like a scoreboard — the same row as ScoreboardRow.swift:
 * teams and scores on the left, a hairline, then clock/status and league.
 */
@Composable
fun ScoreboardRow(match: LiveMatch, now: Long, favorites: Set<String>) {
    val status = MatchSchedule.status(match, now)
    val homeScore = if (match.scoreText == null) null else match.providerState?.homeScore
    val awayScore = if (match.scoreText == null) null else match.providerState?.awayScore
    Row(
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            TeamLine(match.homeTeam, match.homeLogoUrl, homeScore, awayScore)
            TeamLine(match.awayTeam, match.awayLogoUrl, awayScore, homeScore)
        }
        VerticalDivider(
            Modifier.padding(horizontal = 14.dp).fillMaxHeight().padding(vertical = 2.dp),
            thickness = 0.5.dp,
            color = Palette.separator,
        )
        Column(Modifier.width(80.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            StatusText(match, status, now)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                if (match.homeTeam in favorites || match.awayTeam in favorites) {
                    Icon(Icons.Filled.Star, null, tint = Palette.star, modifier = Modifier.size(11.dp))
                }
                Text(
                    if (match.sources.isEmpty()) "暂无线路" else match.league,
                    fontSize = 12.sp,
                    color = if (match.sources.isEmpty()) Palette.tertiaryText else Palette.secondaryText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun TeamLine(name: String, logo: String?, score: Int?, other: Int?) {
    // A side that is behind steps back, the way a scoreboard dims it.
    val behind = score != null && other != null && score < other
    val color = if (behind) Palette.secondaryText else Palette.primaryText
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        TeamCrest(logo, name, 22.dp)
        Text(
            name,
            fontSize = 16.sp,
            color = color,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (score != null) {
            Text("$score", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = color)
        }
    }
}

@Composable
private fun StatusText(match: LiveMatch, status: MatchStatus, now: Long) {
    val shown = MatchSchedule.displayTime(match.time, now)
    val clock = if (shown.day.isEmpty() || shown.day == "今天") shown.clock else "${shown.day} ${shown.clock}"
    when (status) {
        is MatchStatus.Live -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            LiveDot()
            StatusLabel(status.label, Palette.live)
        }
        MatchStatus.Finished -> StatusLabel("已结束", Palette.secondaryText)
        is MatchStatus.Interrupted -> StatusLabel(status.label, Palette.secondaryText)
        is MatchStatus.Upcoming -> StatusLabel(clock, if (status.startsInMinutes <= 90) Palette.accent else Palette.primaryText)
        MatchStatus.Scheduled, MatchStatus.Unknown -> StatusLabel(clock, Palette.primaryText)
    }
}

@Composable
private fun StatusLabel(text: String, color: Color) {
    Text(text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = color, maxLines = 1, overflow = TextOverflow.Ellipsis)
}

/** Long-press menu on a fixture: follow or unfollow either side. */
@Composable
fun FollowMenu(expanded: Boolean, match: LiveMatch, preferences: Preferences, favorites: Set<String>, onDismiss: () -> Unit) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        for (team in listOf(match.homeTeam, match.awayTeam)) {
            val following = team in favorites
            DropdownMenuItem(
                text = { Text(if (following) "取消关注 $team" else "关注 $team") },
                leadingIcon = { Icon(if (following) Icons.Outlined.StarOutline else Icons.Outlined.Star, null) },
                onClick = { preferences.toggleFavorite(team); onDismiss() },
            )
        }
    }
}

/** A fixture as a grouped-list cell, with the long-press follow menu. */
@Composable
fun MatchCell(
    match: LiveMatch,
    index: Int,
    count: Int,
    now: Long,
    favorites: Set<String>,
    preferences: Preferences,
    onOpen: (LiveMatch) -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Box {
        GroupedCell(index, count, onClick = { onOpen(match) }, onLongClick = { menu = true }, dividerInset = 48.dp) {
            ScoreboardRow(match, now, favorites)
        }
        FollowMenu(menu, match, preferences, favorites) { menu = false }
    }
}

fun LazyListScope.matchSection(
    key: String,
    title: String,
    matches: List<LiveMatch>,
    now: Long,
    favorites: Set<String>,
    preferences: Preferences,
    onOpen: (LiveMatch) -> Unit,
) {
    item(key = "header-$key") { SectionHeader(title, matches.size) }
    matches.forEachIndexed { index, match ->
        item(key = "$key-${match.id}") {
            MatchCell(match, index, matches.size, now, favorites, preferences, onOpen)
        }
    }
}

/** The ContentUnavailableView counterpart: big symbol, title, one line, optional action. */
@Composable
fun EmptyState(
    icon: ImageVector,
    title: String,
    message: String? = null,
    action: (@Composable () -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(icon, null, tint = Palette.secondaryText, modifier = Modifier.size(52.dp))
        Spacer(Modifier.height(14.dp))
        Text(title, fontSize = 20.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
        if (message != null) {
            Spacer(Modifier.height(6.dp))
            Text(message, fontSize = 15.sp, color = Palette.secondaryText, textAlign = TextAlign.Center)
        }
        if (action != null) {
            Spacer(Modifier.height(16.dp))
            action()
        }
    }
}

/** Grey shape-only rows while the first fetch is in flight. */
@Composable
fun PlaceholderRow() {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            repeat(2) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(Modifier.size(22.dp).clip(CircleShape).background(Palette.fill))
                    Box(Modifier.width(110.dp).height(14.dp).clip(RoundedCornerShape(7.dp)).background(Palette.fill))
                }
            }
        }
        Column(Modifier.width(80.dp).padding(start = 14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.width(44.dp).height(12.dp).clip(RoundedCornerShape(6.dp)).background(Palette.fill))
            Box(Modifier.width(56.dp).height(10.dp).clip(RoundedCornerShape(5.dp)).background(Palette.fill))
        }
    }
}

val listContentPadding = PaddingValues(bottom = 24.dp)
