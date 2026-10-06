package com.leeguoo.jrkan.ui

import android.content.Context
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.ManageAccounts
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.WorkspacePremium
import androidx.compose.material.icons.outlined.PersonAdd
import androidx.compose.material.icons.outlined.WorkspacePremium
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.leeguoo.jrkan.account.AccountConfig
import com.leeguoo.jrkan.account.AccountSession
import kotlinx.coroutines.launch

fun openInBrowserTab(context: Context, url: String) {
    CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(context, url.toUri())
}

/** The settings row: who is signed in and the membership line. */
@Composable
fun AccountSummary(account: AccountSession) {
    val stored by account.account.collectAsState()
    val profile = stored?.profile
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Avatar(profile?.displayName ?: "", 40)
        Column {
            Text(if (stored == null) "登录 leeguoo 账号" else profile?.displayName ?: "leeguoo 账号", fontSize = 16.sp)
            Text(
                if (stored == null) "可选，只用于会员权益" else (stored?.membership ?: account.membership).summary(),
                fontSize = 13.sp, color = Palette.secondaryText,
            )
        }
    }
}

/**
 * Sign-in and account status (AccountScreen.swift minus Sign in with Apple):
 * every method goes through the account center's page in a browser tab and
 * comes back through the com.leeguoo.jrskan.tv:/oauth/callback redirect.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountRoute(account: AccountSession, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val stored by account.account.collectAsState()
    val signingIn by account.isSigningIn.collectAsState()
    val refreshing by account.isRefreshing.collectAsState()
    val error by account.lastError.collectAsState()

    LaunchedEffect(Unit) { account.refreshIfStale(60_000) }
    // Coming back from the purchase page in the browser.
    LifecycleResumeEffect(Unit) {
        if (account.isSignedIn) scope.launch { account.refreshAccount() }
        onPauseOrDispose { }
    }

    Scaffold(
        containerColor = Palette.background,
        topBar = {
            TopAppBar(
                title = { Text("账号") },
                navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "返回") } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Palette.background),
            )
        },
    ) { padding ->
        LazyColumn(Modifier.padding(padding).fillMaxSize(), contentPadding = listContentPadding) {
            val current = stored
            if (current == null) {
                item {
                    Column(Modifier.padding(start = 32.dp, end = 32.dp, top = 16.dp, bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text("登录 leeguoo 账号", fontSize = 20.sp, fontWeight = FontWeight.Bold)
                        Text("会员权益在手机、平板、电脑和电视上通用。不登录也能正常看比赛。", fontSize = 14.sp, color = Palette.secondaryText)
                    }
                }
                item {
                    Column(Modifier.padding(top = 16.dp)) {
                        GroupedCell(0, 1, onClick = if (signingIn) null else {
                            { openInBrowserTab(context, account.beginBrowserSignIn()) }
                        }) {
                            ActionRow(Icons.Outlined.PersonAdd, if (signingIn) "正在登录…" else "使用邮箱、Google 或 GitHub 登录", Palette.accent)
                        }
                    }
                }
                error?.let { item { Footer(it, Palette.live) } }
            } else {
                val membership = current.membership
                val member = membership.isActive()
                item {
                    Column(Modifier.padding(top = 16.dp)) {
                        GroupedCell(0, 1) {
                            Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                Avatar(current.profile?.displayName ?: "", 52)
                                Column {
                                    Text(current.profile?.displayName ?: "正在读取账号…", fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                                    current.profile?.visibleEmail?.let { Text(it, fontSize = 14.sp, color = Palette.secondaryText) }
                                }
                            }
                        }
                    }
                }
                item { GroupTitle("会员") }
                item {
                    GroupedCell(0, 3, dividerInset = 52.dp) {
                        ActionRow(
                            if (member) Icons.Filled.WorkspacePremium else Icons.Outlined.WorkspacePremium,
                            membership.summary(),
                            if (member) Palette.primaryText else Palette.secondaryText,
                        )
                    }
                }
                item {
                    GroupedCell(1, 3, onClick = { openInBrowserTab(context, AccountConfig.membershipUrl) }, dividerInset = 52.dp) {
                        ActionRow(Icons.Filled.CreditCard, membership.purchaseTitle(), Palette.accent)
                    }
                }
                item {
                    GroupedCell(2, 3, onClick = if (refreshing) null else { { scope.launch { account.refreshAccount() } } }) {
                        ActionRow(Icons.Filled.Refresh, if (refreshing) "正在刷新…" else "刷新会员状态", Palette.accent)
                    }
                }
                item {
                    Footer(
                        if (membership.isTrial == true && member) "新账号赠送三个月会员。到期后 ${AccountConfig.PRICE_LABEL}，在网页上用微信或支付宝付款（爱发电），回到这里自动刷新。"
                        else "在网页上用微信或支付宝付款（爱发电），每次续一个月，回到这里自动刷新。",
                        Palette.secondaryText,
                    )
                }
                item { GroupTitle("账号") }
                item {
                    GroupedCell(0, 2, onClick = { openInBrowserTab(context, AccountConfig.manageUrl) }, dividerInset = 52.dp) {
                        ActionRow(Icons.Filled.ManageAccounts, "在账号中心管理登录方式", Palette.accent)
                    }
                }
                item {
                    GroupedCell(1, 2, onClick = { scope.launch { account.signOut() } }) {
                        ActionRow(Icons.AutoMirrored.Filled.Logout, "退出登录", Palette.live)
                    }
                }
                error?.let { item { Footer(it, Palette.live) } }
            }
        }
    }
}

@Composable
private fun ActionRow(icon: ImageVector, text: String, tint: Color) {
    Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(22.dp))
        Text(text, fontSize = 16.sp, color = tint)
    }
}

@Composable
private fun Footer(text: String, color: Color) {
    Text(text, fontSize = 12.sp, color = color, modifier = Modifier.padding(horizontal = 32.dp, vertical = 8.dp))
}

@Composable
private fun Avatar(name: String, size: Int) {
    Box(
        Modifier.size(size.dp).clip(CircleShape).background(Palette.accent.copy(alpha = 0.25f)),
        contentAlignment = Alignment.Center,
    ) {
        Text(name.take(1).ifEmpty { "?" }, fontSize = (size * 0.42).sp, fontWeight = FontWeight.Bold, color = Palette.accent)
    }
}
