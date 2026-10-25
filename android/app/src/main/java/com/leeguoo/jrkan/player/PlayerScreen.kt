@file:kotlin.OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.leeguoo.jrkan.player

import android.Manifest
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.view.View
import android.view.ViewGroup
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.OptIn
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateOffsetAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.systemBarsIgnoringVisibility
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Crop
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.FitScreen
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.Subtitles
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.leeguoo.jrkan.data.AppConfig
import com.leeguoo.jrkan.recording.HlsRecorder
import com.leeguoo.jrkan.recording.RecordingService
import com.leeguoo.jrkan.recording.Recordings
import com.leeguoo.jrkan.state.AppConfigStore
import com.leeguoo.jrkan.state.MatchInsightsModel
import com.leeguoo.jrkan.state.MatchPlaybackModel
import com.leeguoo.jrkan.ui.LedScore
import com.leeguoo.jrkan.ui.LiveBadge
import com.leeguoo.jrkan.ui.Palette
import com.leeguoo.jrkan.ui.ScoreShape
import com.leeguoo.jrkan.ui.SportsInsightsBinding
import com.leeguoo.jrkan.ui.SportsStatsTabs
import com.leeguoo.jrkan.ui.StatsTab
import com.leeguoo.jrkan.ui.TeamCrest
import com.leeguoo.jrkan.ui.chakraStyle
import com.leeguoo.jrkan.ui.scoreboardGround
import com.leeguoo.jrkan.ui.splitScore
import kotlin.random.Random
import kotlinx.coroutines.delay

private val barsInsets: WindowInsets
    @Composable get() = WindowInsets.systemBarsIgnoringVisibility.union(WindowInsets.displayCutout)

/** What the scoreboard chip shows: provider snapshot first, else the listing score. */
private data class PlayerScore(
    val home: String, val away: String, val homeBadge: String?, val awayBadge: String?,
    val score: Pair<String, String>?, val clock: String?,
)

@Composable
private fun rememberPlayerScore(model: MatchPlaybackModel): PlayerScore {
    val insights by model.insights.state.collectAsState()
    val match = model.match
    val snapshot = insights.snapshot
    return if (snapshot != null) {
        PlayerScore(snapshot.left, snapshot.right, snapshot.leftBadge ?: match.homeLogoUrl, snapshot.rightBadge ?: match.awayLogoUrl,
            splitScore(snapshot.score), snapshot.period.ifBlank { null })
    } else {
        PlayerScore(match.homeTeam, match.awayTeam, match.homeLogoUrl, match.awayLogoUrl, splitScore(match.scoreText), null)
    }
}

/**
 * The player. Landscape: full-bleed video with scoreboard chrome; 数据 shrinks
 * the video to the left and opens the stats panel beside it (video keeps
 * playing). Upright phone: video pinned on top, score strip, stats tabs below.
 * Media3 keeps play/pause; its time bar is hidden (live streams).
 */
@OptIn(UnstableApi::class)
@Composable
fun PlayerScreen(model: MatchPlaybackModel, inPictureInPicture: Boolean, onPictureInPicture: () -> Unit) {
    val context = LocalContext.current
    val state by model.state.collectAsState()
    val fills by PlayerSession.fillsScreen.collectAsState()
    val fullScreen by PlayerSession.fullScreen.collectAsState()
    var controlsVisible by remember { mutableStateOf(true) }
    var showsStatistics by rememberSaveable { mutableStateOf(false) }
    var showsLines by remember { mutableStateOf(false) }
    var visibleNotice by remember { mutableStateOf<String?>(null) }
    SportsInsightsBinding(model, enabled = !inPictureInPicture)
    LaunchedEffect(state.notice) {
        visibleNotice = state.notice
        if (visibleNotice != null) { delay(6_000); visibleNotice = null }
    }
    val player = remember { PlayerSession.player(context) }
    val configuration = LocalConfiguration.current
    val portrait = !inPictureInPicture && configuration.orientation == Configuration.ORIENTATION_PORTRAIT

    BackHandler {
        when {
            showsLines -> showsLines = false
            fullScreen -> PlayerSession.setFullScreen(false)
            else -> PlayerSession.dismiss()
        }
    }

    val video = @Composable {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                PlayerView(ctx).apply {
                    layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
                    this.player = player
                    setShowNextButton(false)
                    setShowPreviousButton(false)
                    setShowFastForwardButton(false)
                    setShowRewindButton(false)
                    setControllerVisibilityListener(PlayerView.ControllerVisibilityListener { visibility ->
                        controlsVisible = visibility == View.VISIBLE
                    })
                    hideTimeBar()
                }
            },
            update = { view ->
                view.useController = !inPictureInPicture
                view.resizeMode = if (fills && !portrait) AspectRatioFrameLayout.RESIZE_MODE_ZOOM else AspectRatioFrameLayout.RESIZE_MODE_FIT
                view.hideTimeBar()
            },
        )
        if (!inPictureInPicture) WatermarkOverlay()
        SportsDanmakuOverlay(model.insights, inPictureInPicture)
    }

    val notice = visibleNotice ?: if (state.resolvingIndex != null) "正在切换线路…" else null

    when {
        inPictureInPicture -> Box(Modifier.fillMaxSize().background(Color.Black)) { video() }
        portrait -> PortraitPlayer(model, state, video, controlsVisible, notice, onPictureInPicture) { showsLines = true }
        else -> Box(Modifier.fillMaxSize().scoreboardGround()) {
            Row(Modifier.fillMaxSize()) {
                Column(
                    Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .then(if (showsStatistics) Modifier.windowInsetsPadding(barsInsets.only(WindowInsetsSides.Start + WindowInsetsSides.Vertical)).padding(start = 8.dp, top = 12.dp, bottom = 12.dp) else Modifier),
                    verticalArrangement = Arrangement.Center,
                ) {
                    Box(
                        if (showsStatistics) Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(ScoreShape).background(Color.Black)
                        else Modifier.fillMaxSize().background(Color.Black),
                    ) {
                        video()
                        if (showsStatistics) {
                            LiveBadge("直播", Modifier.align(Alignment.TopStart).padding(10.dp), size = 11.sp)
                            GlassLabel("继续播放中", Modifier.align(Alignment.TopEnd).padding(10.dp))
                        } else if (controlsVisible) {
                            LandscapeControls(model, state, fills, fullScreen, onPictureInPicture,
                                onLines = { showsLines = true }, onStatistics = { showsStatistics = true })
                        }
                        if (notice != null) NoticeBubble(notice, Modifier.align(Alignment.Center))
                    }
                    if (showsStatistics) StatsScoreRow(model) { showsStatistics = false }
                }
                if (showsStatistics) {
                    Column(
                        Modifier
                            .width(360.dp)
                            .fillMaxHeight()
                            .windowInsetsPadding(barsInsets.only(WindowInsetsSides.End + WindowInsetsSides.Vertical))
                            .padding(start = 14.dp, end = 12.dp, top = 12.dp, bottom = 12.dp)
                            .clip(ScoreShape)
                            .background(Palette.cell)
                            .border(0.5.dp, Color(0x1AFFECD2), ScoreShape),
                    ) {
                        SportsStatsTabs(model.insights, listOf(StatsTab.PlayersShort, StatsTab.TeamShort, StatsTab.Periods), Modifier.fillMaxSize())
                    }
                }
            }
            if (showsLines) LineMenu(model, state, Modifier.align(Alignment.TopEnd).windowInsetsPadding(barsInsets).padding(end = 16.dp, top = 64.dp)) { showsLines = false }
        }
    }
    if (portrait && showsLines) {
        Box(Modifier.fillMaxSize()) {
            LineMenu(model, state, Modifier.align(Alignment.TopCenter).windowInsetsPadding(WindowInsets.statusBars).padding(top = 64.dp)) { showsLines = false }
        }
    }
}

/** Live streams have no useful timeline; keep Media3's centre play/pause only. */
@OptIn(UnstableApi::class)
private fun PlayerView.hideTimeBar() {
    findViewById<View>(androidx.media3.ui.R.id.exo_bottom_bar)?.visibility = View.GONE
    findViewById<View>(androidx.media3.ui.R.id.exo_progress)?.visibility = View.GONE
}

@Composable
private fun BoxScope.LandscapeControls(
    model: MatchPlaybackModel,
    state: MatchPlaybackModel.State,
    fills: Boolean,
    fullScreen: Boolean,
    onPictureInPicture: () -> Unit,
    onLines: () -> Unit,
    onStatistics: () -> Unit,
) {
    val insights by model.insights.state.collectAsState()
    val score = rememberPlayerScore(model)
    // Darken top and bottom bands so the glass controls read over any picture.
    Box(Modifier.matchParentSize().background(Brush.verticalGradient(
        0f to Color.Black.copy(alpha = 0.6f), 0.28f to Color.Transparent, 0.66f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.7f))))
    Row(
        Modifier.align(Alignment.TopCenter).fillMaxWidth()
            // The bars are hidden while playing; pad for them anyway so the
            // buttons are not inside the swipe-to-reveal edge, which eats taps.
            .windowInsetsPadding(barsInsets).padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        GlassIcon(Icons.Filled.Close, "关闭") { PlayerSession.dismiss() }
        ScoreChip(score)
        Spacer(Modifier.weight(1f))
        if (insights.mid != null) {
            GlassIcon(Icons.Filled.Subtitles, if (insights.danmakuEnabled) "关闭弹幕" else "开启弹幕",
                tint = if (insights.danmakuEnabled) Palette.primaryText else Palette.tertiaryText) { model.insights.toggleDanmaku() }
        }
        GlassIcon(if (fills) Icons.Filled.FitScreen else Icons.Filled.Crop, if (fills) "完整画面" else "铺满屏幕") { PlayerSession.toggleFill() }
        GlassIcon(Icons.Filled.PictureInPictureAlt, "画中画", onClick = onPictureInPicture)
        if (fullScreen) GlassIcon(Icons.Filled.FullscreenExit, "退出全屏") { PlayerSession.setFullScreen(false) }
    }
    Row(
        Modifier.align(Alignment.BottomCenter).fillMaxWidth()
            .windowInsetsPadding(barsInsets).padding(horizontal = 16.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        LiveBadge("直播")
        LineBadge(model, state, onLines)
        Spacer(Modifier.weight(1f))
        RecordButton(model, state)
        GlassButton(Icons.Filled.BarChart, "数据", onClick = onStatistics)
    }
}

/** close ▾ · crest · LED score · clock · crest · 全屏, with the stats tabs below. */
@Composable
private fun PortraitPlayer(
    model: MatchPlaybackModel,
    state: MatchPlaybackModel.State,
    video: @Composable () -> Unit,
    controlsVisible: Boolean,
    notice: String?,
    onPictureInPicture: () -> Unit,
    onLines: () -> Unit,
) {
    val score = rememberPlayerScore(model)
    val insights by model.insights.state.collectAsState()
    Column(Modifier.fillMaxSize().scoreboardGround().windowInsetsPadding(WindowInsets.statusBars)) {
        Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).background(Color.Black)) {
            video()
            if (controlsVisible) {
                LiveBadge("直播", Modifier.align(Alignment.TopStart).padding(10.dp), size = 11.sp)
                Row(Modifier.align(Alignment.TopEnd).padding(8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (insights.mid != null) {
                        GlassIcon(Icons.Filled.Subtitles, if (insights.danmakuEnabled) "关闭弹幕" else "开启弹幕", size = 32.dp,
                            tint = if (insights.danmakuEnabled) Palette.primaryText else Palette.tertiaryText) { model.insights.toggleDanmaku() }
                    }
                    GlassIcon(Icons.Filled.PictureInPictureAlt, "画中画", size = 32.dp, onClick = onPictureInPicture)
                }
                Row(Modifier.align(Alignment.BottomStart).padding(10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    LineBadge(model, state, onLines, compact = true)
                    RecordButton(model, state, compact = true)
                }
            }
            if (notice != null) NoticeBubble(notice, Modifier.align(Alignment.Center))
        }
        Row(
            Modifier.fillMaxWidth()
                .background(Brush.horizontalGradient(listOf(Color(0x591F4FA3), Color(0xFF141210), Color(0x52C8102E))))
                .padding(horizontal = 10.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GlassIcon(Icons.Filled.ExpandMore, "收起", size = 32.dp) { PlayerSession.dismiss() }
            Row(Modifier.weight(1f).padding(start = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                TeamCrest(score.homeBadge, score.home, 28.dp)
                Text(score.home, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                val s = score.score
                if (s != null) LedScore(s.first, s.second, 32.sp, colonPadding = 4.dp)
                else Text("VS", style = chakraStyle(18.sp, FontWeight.Bold, Palette.tertiaryText))
                score.clock?.let { Text(it, style = chakraStyle(11.sp, FontWeight.Bold, Palette.live), maxLines = 1) }
            }
            Row(Modifier.weight(1f).padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.End)) {
                Text(score.away, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                TeamCrest(score.awayBadge, score.away, 28.dp)
            }
            GlassIcon(Icons.Filled.Fullscreen, "全屏", size = 32.dp) { PlayerSession.setFullScreen(true) }
        }
        SportsStatsTabs(model.insights, listOf(StatsTab.Overview, StatsTab.Players, StatsTab.Team), Modifier.fillMaxWidth().weight(1f), initial = 1)
    }
}

/** Score line under the shrunk video while the stats panel is open. */
@Composable
private fun StatsScoreRow(model: MatchPlaybackModel, onClose: () -> Unit) {
    val score = rememberPlayerScore(model)
    Row(Modifier.fillMaxWidth().padding(top = 10.dp, start = 2.dp, end = 2.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        TeamCrest(score.homeBadge, score.home, 22.dp)
        val s = score.score
        if (s != null) LedScore(s.first, s.second, 26.sp, colonPadding = 4.dp)
        else Text("${score.home} vs ${score.away}", fontSize = 13.sp, maxLines = 1)
        TeamCrest(score.awayBadge, score.away, 22.dp)
        score.clock?.let { Text(it, style = chakraStyle(12.sp, FontWeight.Bold, Palette.live), maxLines = 1) }
        Spacer(Modifier.weight(1f))
        GlassButton(Icons.Filled.FullscreenExit, "收起数据", height = 32.dp, onClick = onClose)
    }
}

@Composable
private fun ScoreChip(score: PlayerScore) {
    Row(
        Modifier.height(40.dp).clip(ScoreShape).background(Palette.glass).border(0.5.dp, Palette.glassBorder, ScoreShape)
            .padding(start = 10.dp, end = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        TeamCrest(score.homeBadge, score.home, 22.dp)
        Text(score.home, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Palette.primaryText, maxLines = 1,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 96.dp))
        val s = score.score
        if (s != null) LedScore(s.first, s.second, 23.sp, colonPadding = 3.dp)
        else Text("vs", style = chakraStyle(13.sp, FontWeight.Bold, Palette.secondaryText))
        Text(score.away, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Palette.primaryText, maxLines = 1,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 96.dp))
        TeamCrest(score.awayBadge, score.away, 22.dp)
        score.clock?.let { Text(it, style = chakraStyle(12.sp, FontWeight.Bold, Palette.live), maxLines = 1) }
    }
}

/** "✓ 自动 · <channel>" or "✋ 手动 · <channel>"; opens the line menu. */
@Composable
private fun LineBadge(model: MatchPlaybackModel, state: MatchPlaybackModel.State, onClick: () -> Unit, compact: Boolean = false) {
    val playing = state.playback
    val manual = state.choseManually
    val name = playing?.sourceName ?: state.resolvingIndex?.let { model.resolvedChannels.getOrNull(it)?.name } ?: "选择线路"
    Row(
        Modifier.height(if (compact) 28.dp else 36.dp).clip(ScoreShape).background(Palette.glass).border(0.5.dp, Palette.glassBorder, ScoreShape)
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = if (compact) 10.dp else 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(if (compact) 5.dp else 8.dp),
    ) {
        Icon(if (manual) Icons.Filled.PanTool else Icons.Filled.Check, null, tint = if (manual) Palette.accent else Palette.ok,
            modifier = Modifier.size(if (compact) 12.dp else 15.dp))
        Text("${if (manual) "手动" else "自动"} · $name", color = Palette.primaryText, fontSize = if (compact) 11.sp else 13.sp,
            fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 200.dp))
        if (!compact) Icon(Icons.Filled.UnfoldMore, null, tint = Palette.secondaryText, modifier = Modifier.size(14.dp))
    }
}

/**
 * The line menu: channels in automatic-selection order (Preferences.rankedIndices),
 * the playing one tagged 自动/手动 · 播放中. Picking one is a manual choice.
 */
@Composable
private fun LineMenu(model: MatchPlaybackModel, state: MatchPlaybackModel.State, modifier: Modifier, onClose: () -> Unit) {
    val ranked = model.rankedIndices
    val channels = model.resolvedChannels
    val current = state.playback?.index
    val backup = if (model.automaticFallbackEnabled && current != null) model.nextUntriedIndex(current) else null
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f))
        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onClose)) {
        Column(
            modifier.width(300.dp).clip(ScoreShape).background(Color(0xF01A1714)).border(0.5.dp, Palette.glassBorder, ScoreShape)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
        ) {
            Column(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text("线路", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Palette.primaryText)
                Text("按优先级自动选择，失效会自动换下一条", fontSize = 12.sp, color = Palette.secondaryText, lineHeight = 17.sp)
            }
            Column(Modifier.heightIn(max = 260.dp).verticalScroll(rememberScrollState())) {
                ranked.forEachIndexed { position, index ->
                    val source = channels.getOrNull(index) ?: return@forEachIndexed
                    val playing = index == current
                    val (tag, tagColor) = when {
                        state.resolvingIndex == index -> "正在解析…" to Palette.secondaryText
                        playing -> (if (state.choseManually) "手动 · 播放中" else "自动 · 播放中") to (if (state.choseManually) Palette.accent else Palette.ok)
                        index in state.stalledIndices || index in state.failedResolutionIndices -> "刚才失败" to Palette.tertiaryText
                        index == backup -> "备用" to Palette.secondaryText
                        else -> null to Palette.secondaryText
                    }
                    Box(Modifier.fillMaxWidth().height(1.dp).background(Color(0x14FFECD2)))
                    Row(
                        Modifier.fillMaxWidth().height(42.dp).clickable {
                            onClose()
                            if (!playing && state.resolvingIndex == null) model.startManualPlayback(index)
                        }.padding(horizontal = 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Text("${position + 1}", style = chakraStyle(12.sp, FontWeight.SemiBold, Palette.tertiaryText), modifier = Modifier.width(18.dp))
                        Text(source.name, fontSize = 14.sp, fontWeight = if (playing) FontWeight.Bold else FontWeight.Medium,
                            color = if (playing) Palette.primaryText else Color(0xFFCFC5B5), maxLines = 1, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f))
                        if (tag != null) {
                            Text(tag, fontSize = 11.sp, fontWeight = FontWeight.Bold, color = tagColor, maxLines = 1,
                                modifier = Modifier.clip(ScoreShape).background(if (playing) tagColor.copy(alpha = 0.15f) else Color(0x14FFECD2))
                                    .padding(horizontal = 8.dp, vertical = 3.dp))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GlassIcon(icon: ImageVector, label: String, size: Dp = 40.dp, tint: Color = Palette.primaryText, onClick: () -> Unit) {
    Box(
        Modifier.size(size).clip(ScoreShape).background(Palette.glass).border(0.5.dp, Palette.glassBorder, ScoreShape)
            .clickable(role = Role.Button, onClickLabel = label, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, label, tint = tint, modifier = Modifier.size(size * 0.5f)) }
}

@Composable
private fun GlassButton(icon: ImageVector?, label: String, height: Dp = 36.dp, enabled: Boolean = true, leading: (@Composable () -> Unit)? = null, onClick: () -> Unit) {
    Row(
        Modifier.height(height).clip(ScoreShape).background(Palette.glass).border(0.5.dp, Palette.glassBorder, ScoreShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick).padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        leading?.invoke()
        if (icon != null) Icon(icon, null, tint = Palette.primaryText, modifier = Modifier.size(16.dp))
        Text(label, color = if (enabled) Palette.primaryText else Palette.tertiaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

@Composable
private fun GlassLabel(text: String, modifier: Modifier) {
    Text(text, modifier = modifier.clip(ScoreShape).background(Palette.glass).border(0.5.dp, Palette.glassBorder, ScoreShape)
        .padding(horizontal = 10.dp, vertical = 5.dp), color = Palette.primaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
}

@Composable
private fun NoticeBubble(text: String, modifier: Modifier) {
    Text(text, color = Palette.primaryText, fontSize = 13.sp,
        modifier = modifier.padding(24.dp).clip(ScoreShape).background(Color.Black.copy(alpha = 0.65f)).padding(horizontal = 14.dp, vertical = 8.dp))
}

/**
 * Starts a recording of what is playing, or shows the running one with stop
 * and "record this channel instead" once the viewer has switched channels.
 * The first recording asks for notification permission: the foreground
 * notification is where a background recording is seen and stopped.
 */
@Composable
private fun RecordButton(model: MatchPlaybackModel, state: MatchPlaybackModel.State, compact: Boolean = false) {
    val context = LocalContext.current
    val active by Recordings.active.collectAsState()
    val recorder = active.values.firstOrNull { it.info.value.matchId == model.match.id }
    var menu by remember { mutableStateOf(false) }
    val height = if (compact) 28.dp else 36.dp

    fun start() {
        val playback = model.state.value.playback ?: return
        Recordings.start(model.match, model.resolvedChannels, playback.index, playback.url)
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { start() }

    if (recorder == null) {
        GlassButton(null, "录像", height = height, enabled = state.playback != null,
            leading = { Box(Modifier.size(9.dp).clip(RoundedCornerShape(5.dp)).background(Palette.live)) }) {
            if (Build.VERSION.SDK_INT >= 33 &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) {
                permission.launch(Manifest.permission.POST_NOTIFICATIONS)
            } else {
                start()
            }
        }
        return
    }

    val info by recorder.info.collectAsState()
    val recordingIndex by recorder.sourceIndex.collectAsState()
    val phase by recorder.phase.collectAsState()
    Box {
        GlassButton(null, RecordingService.duration(info.duration), height = height, leading = {
            Icon(Icons.Filled.FiberManualRecord, null, tint = if (phase == HlsRecorder.Phase.Reconnecting) Palette.flame else Palette.live, modifier = Modifier.size(10.dp))
        }) { menu = true }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            val playing = state.playback
            if (playing != null && playing.index != recordingIndex && playing.index in recorder.sources.indices) {
                DropdownMenuItem(
                    text = { Text("改录当前线路「${playing.sourceName}」") },
                    onClick = { menu = false; recorder.switchSource(playing.index) },
                )
            }
            DropdownMenuItem(text = { Text("停止录像") }, onClick = { menu = false; Recordings.stop(recorder.id) })
        }
    }
}

/**
 * The watermark from the remote config (WatermarkView in DesignSystem.swift):
 * hops to a random spot every `interval` seconds, fading out and back in and
 * rotating through the configured texts; drifts slowly; or sits bottom-right.
 * It keeps out of the top and bottom bands, where the controls appear.
 */
@Composable
private fun WatermarkOverlay() {
    val config by AppConfigStore.config.collectAsState()
    val member by AppConfigStore.isMember.collectAsState()
    val settings = config.visibleWatermark(member) ?: return
    val density = LocalDensity.current

    BoxWithConstraints(Modifier.fillMaxSize().windowInsetsPadding(barsInsets).padding(20.dp)) {
        val areaWidth = constraints.maxWidth.toFloat()
        val areaHeight = constraints.maxHeight.toFloat()
        var textSize by remember { mutableStateOf(IntSize.Zero) }
        var textIndex by remember(settings) { mutableIntStateOf(0) }
        // Fractions of the free space, so a rotation keeps the text on screen.
        var spot by remember(settings) { mutableStateOf(Offset(Random.nextFloat(), Random.nextFloat())) }
        val alpha = remember(settings) { Animatable(settings.opacity.toFloat()) }

        LaunchedEffect(settings) {
            if (settings.motion == AppConfig.Motion.Fixed) return@LaunchedEffect
            while (true) {
                delay((settings.interval * 1000).toLong())
                if (settings.motion == AppConfig.Motion.Hop) alpha.animateTo(0f, tween(600))
                if (settings.texts.size > 1) textIndex = (textIndex + 1) % settings.texts.size
                spot = Offset(Random.nextFloat(), Random.nextFloat())
                if (settings.motion == AppConfig.Motion.Hop) alpha.animateTo(settings.opacity.toFloat(), tween(600))
            }
        }

        val driftMillis = (settings.interval * 1000).toInt()
        val fraction by animateOffsetAsState(
            spot,
            animationSpec = if (settings.motion == AppConfig.Motion.Drift) tween(driftMillis, easing = LinearEasing) else snap(),
            label = "watermark",
        )
        val top = areaHeight * 0.15f
        val bottom = areaHeight * 0.8f
        val offset = if (settings.motion == AppConfig.Motion.Fixed) {
            // Above Media3's bottom bar so it never covers the settings gear.
            IntOffset((areaWidth - textSize.width).toInt(), (areaHeight - textSize.height - with(density) { 44.dp.toPx() }).toInt())
        } else {
            IntOffset(
                (fraction.x * (areaWidth - textSize.width).coerceAtLeast(0f)).toInt(),
                (top + fraction.y * (bottom - top - textSize.height).coerceAtLeast(0f)).toInt(),
            )
        }
        Text(
            settings.texts[textIndex.coerceIn(0, settings.texts.lastIndex)],
            color = Color.White.copy(alpha = alpha.value),
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.onSizeChanged { textSize = it }.offset { offset },
        )
    }
}
