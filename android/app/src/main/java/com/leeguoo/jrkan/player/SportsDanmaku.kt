package com.leeguoo.jrkan.player

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.leeguoo.jrkan.data.SportsComment
import com.leeguoo.jrkan.state.DanmakuQueue
import com.leeguoo.jrkan.state.MatchInsightsModel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

private data class Flight(val comment: SportsComment, val lane: Int)

/** Display-only, three lanes; comments have no pointer/remote input handlers. */
@Composable
fun SportsDanmakuOverlay(model: MatchInsightsModel, inPip: Boolean) {
    val state by model.state.collectAsState()
    val owner = LocalLifecycleOwner.current
    val queue = remember(model) { DanmakuQueue() }
    val flights = remember(model) { mutableStateListOf<Flight>() }
    val enabled = state.danmakuEnabled && !inPip && state.mid != null
    LaunchedEffect(state.comments, enabled) { if (enabled) queue.offer(state.comments) }
    LaunchedEffect(model, state.mid, enabled, owner) {
        flights.clear(); queue.clearPending()
        if (enabled) owner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            try {
                coroutineScope {
                    launch { model.watchComments() }
                    launch {
                        var lane = 0
                        while (isActive) {
                            delay(2_500)
                            queue.next()?.let { flights.add(Flight(it, lane)); lane = (lane + 1) % 3 }
                        }
                    }
                }
            } finally { flights.clear(); queue.clearPending() }
        }
    }
    DisposableEffect(model) { onDispose { flights.clear(); queue.clearPending() } }
    if (enabled) {
        BoxWithConstraints(Modifier.fillMaxSize().clipToBounds().clearAndSetSemantics {}) {
            val density = LocalDensity.current
            val width = with(density) { maxWidth.toPx() }
            val top = with(density) { maxOf(70.dp, maxHeight * 0.17f).toPx() }
            val line = with(density) { 29.dp.toPx() }
            for (flight in flights.toList()) {
                androidx.compose.runtime.key(flight.comment.id) {
                    FlyingComment(flight, width, top + flight.lane * line) { flights.remove(flight) }
                }
            }
        }
    }
}

@Composable
private fun FlyingComment(flight: Flight, parentWidth: Float, top: Float, onFinished: () -> Unit) {
    val progress = remember(flight.comment.id) { Animatable(1f) }
    var width by remember { mutableIntStateOf(0) }
    LaunchedEffect(flight.comment.id) {
        progress.animateTo(0f, tween(7_000, easing = LinearEasing))
        onFinished()
    }
    Text(flight.comment.text, color = Color.White.copy(alpha = 0.88f), fontSize = 17.sp,
        fontWeight = FontWeight.SemiBold, maxLines = 1,
        style = TextStyle(shadow = Shadow(Color.Black, Offset(1f, 1f), 2f)),
        modifier = Modifier.wrapContentWidth(unbounded = true).onSizeChanged { width = it.width }
            .offset { IntOffset((parentWidth * progress.value - width * (1f - progress.value)).toInt(), top.toInt()) })
}
