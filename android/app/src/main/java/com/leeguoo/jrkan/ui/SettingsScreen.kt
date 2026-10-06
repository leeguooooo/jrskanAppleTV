package com.leeguoo.jrkan.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.leeguoo.jrkan.BuildConfig
import com.leeguoo.jrkan.data.SportFilter
import com.leeguoo.jrkan.state.MatchListModel

/** Mirrors SettingsScreen.swift: account, playback, follows and history, about. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    model: MatchListModel,
    accountSummary: @Composable () -> Unit,
    onOpenAccount: () -> Unit,
    onBack: () -> Unit,
) {
    val prefs = model.preferences
    val autoNext by prefs.autoNextChannel.collectAsState()
    val autoRefresh by prefs.autoRefresh.collectAsState()
    val favorites by prefs.favoriteTeams.collectAsState()
    val recent by prefs.recentWatches.collectAsState()
    val lastChannels by prefs.lastChannels.collectAsState()
    var cleared by remember { mutableStateOf(false) }
    val hasHistory = favorites.isNotEmpty() || recent.isNotEmpty() || lastChannels.isNotEmpty() || prefs.hasHistory

    Scaffold(
        containerColor = Palette.background,
        topBar = {
            TopAppBar(
                title = { Text("设置") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Palette.background),
            )
        },
    ) { padding ->
        LazyColumn(Modifier.padding(padding).fillMaxSize(), contentPadding = listContentPadding) {
            item { GroupTitle("账号") }
            item {
                GroupedCell(0, 1, onClick = onOpenAccount) {
                    Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) { accountSummary() }
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Palette.tertiaryText)
                    }
                }
            }

            item { GroupTitle("播放与刷新") }
            item {
                GroupedCell(0, 2) {
                    ToggleRow("线路失效时自动换线", "无画面或恢复失败时自动换线，正常暂停不受影响。", autoNext, prefs::setAutoNextChannel)
                }
            }
            item {
                GroupedCell(1, 2) {
                    ToggleRow("自动刷新赛程与比分", "赛程每 5 分钟、比分每 30 秒检查；回到前台也会检查。", autoRefresh, prefs::setAutoRefresh)
                }
            }

            item { GroupTitle("关注与记录") }
            val teams = favorites.sorted()
            val rows = teams.size.coerceAtLeast(1) + 1
            if (teams.isEmpty()) {
                item {
                    GroupedCell(0, rows) {
                        Text(
                            "还没有关注球队，长按比赛或在比赛详情里点「关注」添加。",
                            fontSize = 14.sp, color = Palette.secondaryText, modifier = Modifier.padding(16.dp),
                        )
                    }
                }
            } else {
                teams.forEachIndexed { index, team ->
                    item(key = "team-$team") {
                        GroupedCell(index, rows) {
                            Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Filled.Star, null, tint = Palette.accent, modifier = Modifier.size(18.dp))
                                Text(team, fontSize = 16.sp, modifier = Modifier.weight(1f).padding(horizontal = 12.dp))
                                IconButton(onClick = { prefs.toggleFavorite(team) }) {
                                    Icon(Icons.Filled.Close, "取消关注 $team", tint = Palette.tertiaryText)
                                }
                            }
                        }
                    }
                }
            }
            item {
                GroupedCell(rows - 1, rows, onClick = if (hasHistory) {
                    { prefs.clearHistory(); model.setFilter(SportFilter.All); cleared = true }
                } else null) {
                    Text(
                        if (cleared) "已清除" else "清除关注与观看记录",
                        fontSize = 16.sp,
                        color = if (hasHistory) Palette.live else Palette.tertiaryText,
                        modifier = Modifier.padding(16.dp),
                    )
                }
            }

            item { GroupTitle("关于") }
            item {
                GroupedCell(0, 2) {
                    InfoRow("内容来源", "应用只读取公开网页上的赛程与线路，不托管、不重新分发任何视频，也不绕过登录、DRM、付费墙或地域限制。线路由第三方维护，可能随时失效。")
                }
            }
            item {
                GroupedCell(1, 2) {
                    InfoRow("隐私", "不登录也能使用。登录是可选的，只用于会员权益：账号中心保存你的邮箱与登录方式。不接入分析或广告 SDK，关注与观看记录仅存于本机。")
                }
            }
            item {
                Text(
                    "JRKAN · 版本 ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                    fontSize = 12.sp, color = Palette.tertiaryText,
                    modifier = Modifier.padding(horizontal = 32.dp, vertical = 12.dp),
                )
            }
        }
    }
}

@Composable
fun GroupTitle(text: String) {
    Text(
        text,
        fontSize = 13.sp,
        color = Palette.secondaryText,
        modifier = Modifier.padding(start = 32.dp, end = 32.dp, top = 24.dp, bottom = 8.dp),
    )
}

@Composable
private fun ToggleRow(title: String, detail: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, fontSize = 16.sp)
            Text(detail, fontSize = 12.sp, color = Palette.secondaryText)
        }
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedTrackColor = Color(0xFF34C759), checkedThumbColor = Color.White),
            modifier = Modifier.padding(start = 12.dp),
        )
    }
}

@Composable
private fun InfoRow(title: String, value: String) {
    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Text(value, fontSize = 12.sp, color = Palette.secondaryText)
    }
}
