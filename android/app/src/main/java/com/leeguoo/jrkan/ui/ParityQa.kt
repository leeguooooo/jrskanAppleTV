package com.leeguoo.jrkan.ui

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.leeguoo.jrkan.BuildConfig
import com.leeguoo.jrkan.JrkanApp
import com.leeguoo.jrkan.data.*
import com.leeguoo.jrkan.player.PlayerScreen
import com.leeguoo.jrkan.player.PlayerSession
import com.leeguoo.jrkan.state.MatchInsightsModel
import com.leeguoo.jrkan.state.MatchPlaybackModel
import kotlinx.coroutines.delay

/** Debug-only QA entry. Release builds remove this branch and its fixtures. */
@Composable
fun ParityQaScreen(intent: Intent, app: JrkanApp) {
    if (!BuildConfig.DEBUG) return
    val client = remember { TencentSportsClient() }
    val mode = intent.getStringExtra("jrkan_qa").orEmpty()
    val mid = intent.getStringExtra("qa_mid") ?: "100000:10022600101"
    var model by remember { mutableStateOf<MatchPlaybackModel?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    LaunchedEffect(mid, mode) {
        try {
            var match = client.referenceMatch(mid)
            val stream = intent.getStringExtra("qa_stream_url")
            if (mode == "play" && stream != null) match = match.copy(sources =
                listOf(MatchSource("qa-video", "中文高清 Q（测试视频）", stream)) + match.sources)
            val fixtureComments = intent.getBooleanExtra("qa_test_comments", false)
            val provider = object : SportsDataProvider {
                override suspend fun verify(match: LiveMatch, mid: String) = client.verify(match, mid)
                override suspend fun statistics(mid: String, match: LiveMatch) = client.statistics(mid, match)
                override suspend fun comments(mid: String): List<SportsComment> = if (!fixtureComments) client.comments(mid) else {
                    val now = System.currentTimeMillis()
                    (0..5).map { SportsComment("qa-${now / 10_000}-$it", "测试弹幕 ${it + 1} · 比赛评论独立于视频", now) }
                }
            }
            model = MatchPlaybackModel(match, app.preferences, app.scope, insights = MatchInsightsModel(provider))
            if (mode == "play") model?.startSuggestedPlayback()
        } catch (exception: Exception) { error = exception.message }
    }
    val playback = model
    if (playback == null) {
        Box(Modifier.fillMaxSize().background(SportsColors.canvas), contentAlignment = Alignment.Center) {
            Text(error ?: "加载腾讯公开比赛数据…", color = Color.White)
        }
        return
    }
    if (mode == "play") {
        val state by playback.state.collectAsState()
        val presented by PlayerSession.isPresented.collectAsState()
        LaunchedEffect(state.playback?.id) { if (state.playback != null) PlayerSession.show(context, playback) }
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            if (presented) PlayerScreen(playback, false, {}) else Text(state.errorMessage ?: "加载测试视频…", color = Color.White)
            Text("仅调试：本地测试视频${if (intent.getBooleanExtra("qa_test_comments", false)) " / 测试弹幕" else ""}",
                color = Color.White, fontSize = 11.sp, modifier = Modifier.align(Alignment.BottomStart).background(Color.Black.copy(alpha = 0.6f)).padding(4.dp))
        }
    } else {
        SportsInsightsBinding(playback)
        SportsStatsContent(playback.insights, initialPlayers = mode == "players")
    }
}
