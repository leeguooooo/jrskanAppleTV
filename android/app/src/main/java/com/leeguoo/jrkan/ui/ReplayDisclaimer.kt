package com.leeguoo.jrkan.ui

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.DialogProperties

/** What the viewer agrees to before using 回看 (ReplayDisclaimer.swift). */
object ReplayDisclaimer {
    const val TITLE = "回看使用说明"
    val points = listOf(
        "回看里的视频来自微博网友公开发布的内容。本应用只做检索和播放，不制作、不上传任何视频；你自己下载的视频只保存在你的设备上。",
        "仅供个人研究学习使用，版权归原权利人所有。",
        "禁止分享、转发、传播、公开放映这些视频（包括下载到本机的视频），也不得用于任何商业用途。",
        "下载的视频只保存在本应用里，不会出现在相册或文件管理中；研究学习完请及时删除。",
        "如果你是权利人并认为内容侵犯了你的权利，请通过 leeguoo.com 联系我们，我们会及时处理。",
    )
    const val FOOTER = "仅供个人研究学习，禁止分享传播"
    private const val KEY = "replayDisclaimerAcceptedV2"

    fun isAccepted(context: Context) = context.getSharedPreferences("jrkan-replay", Context.MODE_PRIVATE).getBoolean(KEY, false)
    fun accept(context: Context) = context.getSharedPreferences("jrkan-replay", Context.MODE_PRIVATE).edit().putBoolean(KEY, true).apply()
}

/** onAgree null: only re-reading it. */
@Composable
fun ReplayDisclaimerDialog(onAgree: (() -> Unit)?, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = { if (onAgree == null) onDismiss() },
        properties = DialogProperties(dismissOnClickOutside = onAgree == null, dismissOnBackPress = true),
        title = { Text(ReplayDisclaimer.TITLE) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                ReplayDisclaimer.points.forEachIndexed { index, point ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text("${index + 1}", color = Palette.accent, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        Text(point, fontSize = 14.sp)
                    }
                }
            }
        },
        confirmButton = {
            if (onAgree != null) TextButton(onClick = onAgree) { Text("我已阅读并同意", color = Palette.accent) }
            else TextButton(onClick = onDismiss) { Text("知道了", color = Palette.accent) }
        },
        dismissButton = if (onAgree != null) ({ TextButton(onClick = onDismiss) { Text("不同意") } }) else null,
        containerColor = Palette.cell,
    )
}
