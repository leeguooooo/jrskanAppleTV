package com.leeguoo.jrkan.state

import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.MatchSource
import com.leeguoo.jrkan.data.SportsComment
import com.leeguoo.jrkan.data.SportsDataProvider
import com.leeguoo.jrkan.data.SportsSnapshot
import com.leeguoo.jrkan.data.MultiSportsClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/** Polling is owned by a visible/resumed UI consumer, never by playback or recording. */
class MatchInsightsModel(
    private val provider: SportsDataProvider = MultiSportsClient(),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    data class State(
        val mid: String? = null, val snapshot: SportsSnapshot? = null,
        val status: String = "正在匹配本场比赛…", val comments: List<SportsComment> = emptyList(),
        val danmakuEnabled: Boolean = true,
    )
    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state
    private val seen = LinkedHashSet<String>()
    private var generation = 0
    private var verifiedKey: String? = null

    fun setDanmakuEnabled(enabled: Boolean) {
        _state.update { it.copy(danmakuEnabled = enabled, comments = if (enabled) it.comments else emptyList()) }
    }
    fun toggleDanmaku() = setDanmakuEnabled(!_state.value.danmakuEnabled)

    suspend fun watch(match: LiveMatch, channels: List<MatchSource>) {
        val current = ++generation
        suspend fun check() {
            currentCoroutineContext().ensureActive()
            if (current != generation) throw CancellationException("Superseded match data request")
        }
        val channelKey = channels.map { it.pageUrl }.sorted().joinToString(",")
        val routeKey = "${match.id}|${match.homeTeam}|${match.awayTeam}|${match.time}|$channelKey"
        val mid = try {
            if (verifiedKey?.endsWith(routeKey) == true) _state.value.mid else provider.prepare(match, channels)
        } catch (cancel: CancellationException) { throw cancel }
        catch (_: Exception) {
            check(); verifiedKey = null
            _state.update { it.copy(mid = null, snapshot = null, comments = emptyList(), status = "赛事暂未匹配，请稍后重试") }
            return
        }
        if (mid == null) {
            verifiedKey = null; seen.clear()
            _state.update { it.copy(mid = null, snapshot = null, comments = emptyList(), status = "暂无可匹配的本场数据") }
            return
        }
        val key = "$mid|$routeKey"
        if (verifiedKey != key || _state.value.mid != mid) {
            verifiedKey = null
            seen.clear()
            _state.update { it.copy(mid = null, snapshot = null, comments = emptyList(), status = "正在匹配本场比赛…") }
            try {
                check()
                verifiedKey = key
                _state.update { it.copy(mid = mid) }
            } catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) {
                check(); _state.update { it.copy(status = "赛事暂未匹配，请稍后重试") }; return
            }
        }
        while (true) {
            check()
            try {
                val snapshot = provider.statistics(mid, match) { partial ->
                    check(); _state.update { it.copy(snapshot = partial, status = "") }
                }; check()
                _state.update { it.copy(snapshot = snapshot, status = if (snapshot.tables.isEmpty()) "暂无本场技术统计" else "") }
            } catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) { check(); _state.update { it.copy(status = if (it.snapshot == null) "各数据源暂未提供本场统计，稍后自动重试" else "数据更新暂时中断，显示上次结果") } }
            delay(30_000)
        }
    }

    suspend fun watchComments() {
        _state.update { it.copy(comments = emptyList()) }
        val mid = _state.value.mid ?: return
        if (!_state.value.danmakuEnabled) return
        while (true) {
            currentCoroutineContext().ensureActive()
            if (_state.value.mid != mid || !_state.value.danmakuEnabled) return
            try {
                val comments = provider.comments(mid)
                currentCoroutineContext().ensureActive()
                if (_state.value.mid != mid || !_state.value.danmakuEnabled) return
                val added = comments.filter { seen.add(it.id) }
                while (seen.size > 500) seen.remove(seen.first())
                _state.update { state -> state.copy(comments = (state.comments + added)
                    .filter { clock() - it.postedAt < 120_000 }.takeLast(24)) }
            } catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) { /* A comment outage never reaches the stream state. */ }
            delay(10_000)
        }
    }
}

/** A bounded three-lane renderer consumes this queue, at most once per 2.5 s. */
class DanmakuQueue(private val clock: () -> Long = System::currentTimeMillis) {
    private val seen = LinkedHashSet<String>()
    private val queue = ArrayDeque<SportsComment>()
    val size: Int get() = queue.size
    fun offer(comments: List<SportsComment>) {
        for (comment in comments) if (seen.add(comment.id)) queue.addLast(comment)
        while (queue.size > 20) queue.removeFirst()
        while (seen.size > 500) seen.remove(seen.first())
    }
    fun next(): SportsComment? {
        while (queue.isNotEmpty()) {
            val comment = queue.removeFirst()
            if (clock() - comment.postedAt < 120_000) return comment
        }
        return null
    }
    fun clearPending() = queue.clear()
}
