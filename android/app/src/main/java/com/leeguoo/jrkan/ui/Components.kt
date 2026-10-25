package com.leeguoo.jrkan.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.ui.graphics.Brush
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

/** Grouped-list geometry: one 8dp card per section, rows separated by hairlines. */
object Grouped {
    val corner = 8.dp
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
            HorizontalDivider(Modifier.padding(start = dividerInset), thickness = 1.dp, color = Palette.separator)
        }
    }
}

/**
 * Fixed section heading (今日比赛 / 正在进行 …) in Noto Serif SC Black when
 * every glyph is in the subset font; anything else falls back to system sans.
 */
@Composable
fun SectionHeader(title: String, count: Int? = null, modifier: Modifier = Modifier, hint: String? = null) {
    Row(
        modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 22.dp, bottom = 10.dp),
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        HeadingText(title, 22.sp)
        if (count != null) {
            Text("$count", style = chakraStyle(16.sp, FontWeight.Bold, Palette.tertiaryText), modifier = Modifier.padding(bottom = 2.dp))
        }
        Spacer(Modifier.weight(1f))
        if (hint != null) Text(hint, fontSize = 12.sp, color = Palette.secondaryText, modifier = Modifier.padding(bottom = 3.dp))
    }
}

/** Serif heading text; only fixed strings get the subset serif (see [Fonts.headingFamily]). */
@Composable
fun HeadingText(text: String, size: androidx.compose.ui.unit.TextUnit, modifier: Modifier = Modifier, color: Color = Palette.primaryText) {
    val serif = Fonts.headingFamily(text)
    Text(
        text,
        modifier = modifier,
        color = color,
        fontSize = size,
        fontFamily = serif,
        fontWeight = if (serif != null) FontWeight.Black else FontWeight.Bold,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
    )
}

/** Plain pulsing dot; the live label next to it carries the meaning. */
@Composable
fun LiveDot(size: androidx.compose.ui.unit.Dp = 6.dp, color: Color = Palette.live) {
    val transition = rememberInfiniteTransition(label = "live")
    val alpha by transition.animateFloat(
        initialValue = 1f, targetValue = 0.35f,
        animationSpec = infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "alpha",
    )
    Box(Modifier.size(size).alpha(alpha).clip(CircleShape).background(color))
}

/** Solid red live tag (直播 / ● 5 场直播). Red is reserved for live. */
@Composable
fun LiveBadge(text: String, modifier: Modifier = Modifier, size: androidx.compose.ui.unit.TextUnit = 12.sp) {
    Text(
        text,
        modifier = modifier
            .clip(RoundedCornerShape(6.dp))
            .background(Palette.live)
            .padding(horizontal = 8.dp, vertical = 3.dp),
        color = Palette.onAccent,
        fontSize = size,
        fontWeight = FontWeight.Bold,
        maxLines = 1,
    )
}

/** LED scoreboard digits: "58 : 61" with a dim colon. */
@Composable
fun LedScore(home: String, away: String, size: androidx.compose.ui.unit.TextUnit, modifier: Modifier = Modifier, colonPadding: androidx.compose.ui.unit.Dp = 8.dp) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Text(home, style = ledStyle(size), maxLines = 1)
        Text(":", style = ledStyle(size, Color(0xFF4A443C), glow = false), modifier = Modifier.padding(horizontal = colonPadding), maxLines = 1)
        Text(away, style = ledStyle(size), maxLines = 1)
    }
}

/** Score text "58 - 61" / "58:61" split into the two sides, or null. */
fun splitScore(text: String?): Pair<String, String>? {
    val parts = text?.split("-", ":")?.map(String::trim)?.filter(String::isNotEmpty) ?: return null
    return if (parts.size == 2) parts[0] to parts[1] else null
}

/** The amber primary action: dark label on #FFB000, 8dp corners. */
@Composable
fun AmberButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    height: androidx.compose.ui.unit.Dp = 50.dp,
    icon: ImageVector? = Icons.Filled.PlayArrow,
) {
    Button(
        onClick = onClick,
        enabled = enabled,
        shape = ScoreShape,
        colors = ButtonDefaults.buttonColors(
            containerColor = Palette.accent,
            contentColor = Palette.onAccent,
            disabledContainerColor = Palette.accent.copy(alpha = 0.3f),
            disabledContentColor = Palette.onAccent.copy(alpha = 0.6f),
        ),
        contentPadding = PaddingValues(horizontal = 16.dp),
        modifier = modifier.height(height),
    ) {
        if (icon != null) {
            Icon(icon, null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
        }
        Text(text, fontSize = 16.sp, fontWeight = FontWeight.Black, letterSpacing = 0.6.sp)
    }
}

/** Team logo drawn bare; a monogram tile only when there is no logo. */
@Composable
fun TeamCrest(url: String?, teamName: String, size: androidx.compose.ui.unit.Dp) {
    val monogram = @Composable {
        Box(
            Modifier.size(size).clip(RoundedCornerShape(8.dp)).background(Palette.fill),
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
            loading = { Box(Modifier.size(size).clip(RoundedCornerShape(8.dp)).background(Palette.fill)) },
            error = { monogram() },
        )
    }
}

/**
 * The first live match as a big scoreboard card: crests, LED score, live
 * clock and an amber 观看直播 button. The whole card plays, like a row.
 */
@Composable
fun LiveHeroCard(match: LiveMatch, now: Long, onOpen: (LiveMatch) -> Unit) {
    val status = MatchSchedule.status(match, now)
    val score = splitScore(match.scoreText)
    Column(
        Modifier
            .padding(horizontal = Grouped.gutter)
            .fillMaxWidth()
            .clip(ScoreShape)
            .background(Brush.verticalGradient(listOf(Color(0xFF1E1A15), Color(0xFF151210))))
            .border(1.dp, Color(0xFF3A3229), ScoreShape)
            .clickable { onOpen(match) },
    ) {
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(match.league, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Palette.secondaryText, letterSpacing = 0.8.sp,
                maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            if (status is MatchStatus.Live) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    LiveDot()
                    Text(status.label, style = chakraStyle(13.sp, FontWeight.Bold, Palette.live), maxLines = 1)
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(start = 10.dp, end = 10.dp, top = 16.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            HeroTeam(match.homeTeam, match.homeLogoUrl, Modifier.weight(1f))
            if (score != null) LedScore(score.first, score.second, 64.sp)
            else Text("VS", style = chakraStyle(26.sp, FontWeight.Bold, Palette.tertiaryText))
            HeroTeam(match.awayTeam, match.awayLogoUrl, Modifier.weight(1f))
        }
        AmberButton("观看直播", onClick = { onOpen(match) }, modifier = Modifier.fillMaxWidth().padding(16.dp), height = 48.dp)
    }
}

@Composable
private fun HeroTeam(name: String, logo: String?, modifier: Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TeamCrest(logo, name, 60.dp)
        Text(name, fontSize = 16.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
    }
}

/**
 * One fixture as a two-line scoreboard row (ScoreboardRow.swift): crest,
 * team and LED score per line; live clock or kickoff and league at the right.
 */
@Composable
fun ScoreboardRow(match: LiveMatch, now: Long, favorites: Set<String>) {
    val status = MatchSchedule.status(match, now)
    val homeScore = if (match.scoreText == null) null else match.providerState?.homeScore
    val awayScore = if (match.scoreText == null) null else match.providerState?.awayScore
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(7.dp)) {
            TeamLine(match.homeTeam, match.homeLogoUrl, homeScore, awayScore)
            TeamLine(match.awayTeam, match.awayLogoUrl, awayScore, homeScore)
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.width(78.dp), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            StatusText(match, status, now)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                if (match.homeTeam in favorites || match.awayTeam in favorites) {
                    Icon(Icons.Filled.Star, null, tint = Palette.star, modifier = Modifier.size(11.dp))
                }
                Text(
                    if (match.sources.isEmpty()) "暂无线路" else match.league,
                    fontSize = 11.sp,
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
    Row(
        Modifier.alpha(if (behind) 0.5f else 1f),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        TeamCrest(logo, name, 24.dp)
        Text(
            name,
            fontSize = 15.sp,
            fontWeight = FontWeight.Bold,
            color = Palette.primaryText,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (score != null) {
            Text("$score", style = ledStyle(26.sp), textAlign = TextAlign.End, maxLines = 1,
                modifier = Modifier.width(44.dp).height(24.dp))
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
    Text(text, style = chakraStyle(13.sp, FontWeight.Bold, color), maxLines = 1, overflow = TextOverflow.Ellipsis)
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
        GroupedCell(index, count, onClick = { onOpen(match) }, onLongClick = { menu = true }, dividerInset = 0.dp) {
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
    hint: String? = null,
    onOpen: (LiveMatch) -> Unit,
) {
    item(key = "header-$key") { SectionHeader(title, matches.size, hint = hint) }
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
                    Box(Modifier.size(24.dp).clip(RoundedCornerShape(6.dp)).background(Palette.fill))
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
