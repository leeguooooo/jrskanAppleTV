package com.leeguoo.jrkan.state

import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.MatchSource
import com.leeguoo.jrkan.data.SourcePageClient
import com.leeguoo.jrkan.data.StreamResolver
import com.leeguoo.jrkan.data.userMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.UUID

/** A stream already resolved to a playable URL. */
data class PlaybackRequest(
    val url: String,
    val sourceName: String,
    val index: Int,
    val id: String = UUID.randomUUID().toString(),
)

/**
 * Channels and playback for one match, independent of how the screen is
 * drawn. Port of App/Sources/Shared/MatchPlaybackModel.swift: resolve first,
 * present second; failed channels fall through to the next best one.
 */
class MatchPlaybackModel(
    val match: LiveMatch,
    private val preferences: Preferences,
    private val scope: CoroutineScope,
    private val resolver: StreamResolver = StreamResolver(),
    private val sourcePages: SourcePageClient = SourcePageClient(),
    private val clock: () -> Long = System::currentTimeMillis,
) {
    data class State(
        /** null while loading, empty when the page gave nothing usable. */
        val channels: List<MatchSource>? = null,
        val channelNotice: String? = null,
        val playback: PlaybackRequest? = null,
        val resolvingIndex: Int? = null,
        val errorMessage: String? = null,
        val notice: String? = null,
        val stalledIndices: Set<Int> = emptySet(),
        val failedResolutionIndices: Set<Int> = emptySet(),
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state

    private var requestGeneration = 0
    private var confirmedRequestId: String? = null
    private var handledFailureId: String? = null
    private val lastReconnect = mutableMapOf<Int, Long>()
    private var recoveryJob: Job? = null
    private var playbackJob: Job? = null
    private var resolutionMillis = 0L

    // Channels

    /** Parsed channels when the source page gave any, else the homepage entries. */
    val resolvedChannels: List<MatchSource>
        get() = _state.value.channels?.takeIf { it.isNotEmpty() } ?: match.sources

    val isLoadingChannels: Boolean get() = _state.value.channels == null

    val rememberedChannel: MatchSource?
        get() {
            val remembered = preferences.recentWatches.value.firstOrNull { it.id == match.id } ?: return null
            return resolvedChannels.firstOrNull { it.name == remembered.channelName }
        }

    val suggestedChannel: MatchSource?
        get() = preferences.rankedIndices(resolvedChannels, match.id).firstOrNull()?.let { resolvedChannels[it] }

    val automaticFallbackEnabled: Boolean
        get() = preferences.autoNextChannel.value && resolvedChannels.size > 1

    fun subtitle(source: MatchSource, index: Int): String {
        val state = _state.value
        return when {
            state.resolvingIndex == index -> "正在解析线路…"
            index in state.stalledIndices -> "刚才没有画面"
            index in state.failedResolutionIndices -> "刚才未能播放"
            suggestedChannel?.id == source.id &&
                (preferences.channelPerformance.value[source.pageUrl]?.successes ?: 0) > 0 -> "推荐 · 曾播放成功"
            state.channels.isNullOrEmpty() -> "备用入口 · 直接尝试播放"
            source.name.contains("高清") -> "高清频道"
            else -> "主播解说"
        }
    }

    /** The highest-ranked channel not yet failed this visit. */
    fun nextUntriedIndex(after: Int): Int? {
        val state = _state.value
        return preferences.rankedIndices(resolvedChannels, match.id).firstOrNull {
            it != after && it !in state.stalledIndices && it !in state.failedResolutionIndices
        }
    }

    val retryActionTitle: String
        get() {
            val current = _state.value.playback?.index ?: _state.value.resolvingIndex ?: -1
            return nextUntriedIndex(current)?.let { "试线路 ${it + 1}" } ?: "重试"
        }

    fun retryAfterError() {
        val current = _state.value.playback?.index ?: -1
        startPlayback(nextUntriedIndex(current) ?: 0)
    }

    suspend fun loadChannels() {
        _state.update { it.copy(channels = null, channelNotice = null) }
        for (source in match.sources) {
            try {
                val loaded = sourcePages.fetchChannels(source.pageUrl)
                if (loaded.isNotEmpty()) {
                    _state.update { it.copy(channels = loaded) }
                    return
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                continue
            }
        }
        _state.update {
            it.copy(
                channels = emptyList(),
                // With no homepage entries there is nothing to fall back to.
                channelNotice = if (match.sources.isNotEmpty()) "没能读取具体频道，下面是首页备用入口。" else null,
            )
        }
    }

    fun startSuggestedPlayback() {
        val source = suggestedChannel ?: return
        startPlayback(resolvedChannels.indexOf(source))
    }

    // Playback

    fun startPlayback(startIndex: Int, resetStalls: Boolean = true) {
        playbackJob?.cancel()
        playbackJob = scope.launch { resolveAndPlay(startIndex, resetStalls) }
    }

    private suspend fun resolveAndPlay(startIndex: Int, resetStalls: Boolean) {
        val channels = resolvedChannels
        if (startIndex !in channels.indices) return
        requestGeneration += 1
        val generation = requestGeneration
        if (resetStalls) {
            recoveryJob?.cancel()
            lastReconnect.clear()
            _state.update { it.copy(stalledIndices = emptySet(), failedResolutionIndices = emptySet()) }
        }
        _state.update { it.copy(errorMessage = null, notice = null) }

        val tryOthers = preferences.autoNextChannel.value && channels.size > 1
        var index = startIndex
        var attempts = 0
        val failures = mutableListOf<String>()
        try {
            while (index in channels.indices && attempts < channels.size) {
                val source = channels[index]
                _state.update { it.copy(resolvingIndex = index) }
                val started = clock()
                try {
                    val url = resolver.resolve(source.pageUrl)
                    if (generation != requestGeneration) return
                    resolutionMillis = clock() - started
                    confirmedRequestId = null
                    handledFailureId = null
                    val notice = if (index != startIndex) "线路 ${startIndex + 1} 暂不可用，已自动改用线路 ${index + 1}「${source.name}」。" else null
                    _state.update { it.copy(playback = PlaybackRequest(url, source.name, index), notice = notice) }
                    return
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    if (generation != requestGeneration) return
                    val failedIndex = index
                    _state.update { it.copy(failedResolutionIndices = it.failedResolutionIndices + failedIndex) }
                    preferences.recordPlaybackFailure(source)
                    failures += "线路 ${index + 1}：${e.userMessage()}"
                    attempts += 1
                    val next = if (tryOthers) nextUntriedIndex(index) else null
                    index = next ?: break
                }
            }
            _state.update { state ->
                val message = if (state.stalledIndices.isNotEmpty()) {
                    "当前线路都未能播放：${state.stalledIndices.size} 条没有画面，${state.failedResolutionIndices.size} 条暂不可用。可以稍后重试。"
                } else if (failures.size > 1) {
                    "试过 ${failures.size} 条线路，暂时都无法播放。${failures.last()}"
                } else failures.firstOrNull()
                state.copy(playback = null, errorMessage = message)
            }
        } finally {
            if (requestGeneration == generation) _state.update { it.copy(resolvingIndex = null) }
        }
    }

    fun confirmPlayback(requestId: String, startupSeconds: Double) {
        val request = _state.value.playback ?: return
        if (request.id != requestId || confirmedRequestId == requestId || request.index !in resolvedChannels.indices) return
        confirmedRequestId = requestId
        preferences.recordPlaybackSuccess(
            match, resolvedChannels[request.index], request.index, resolutionMillis / 1000.0 + startupSeconds,
        )
        _state.update { it.copy(notice = null) }
    }

    /**
     * A confirmed stream gets one same-channel reconnect per two minutes
     * before other sources are tried.
     */
    fun handleStall(message: String, requestId: String? = null, now: Long = clock()) {
        val request = _state.value.playback ?: return
        if ((requestId != null && request.id != requestId) || handledFailureId == request.id ||
            request.index !in resolvedChannels.indices
        ) return
        handledFailureId = request.id
        val index = request.index
        preferences.recordPlaybackFailure(resolvedChannels[index], now)
        val shouldReconnect = confirmedRequestId == request.id &&
            lastReconnect[index]?.let { now - it >= 120_000 } != false
        val next: Int
        if (shouldReconnect) {
            lastReconnect[index] = now
            next = index
            _state.update { it.copy(notice = "直播中断，正在重新连接线路 ${index + 1}…") }
        } else {
            _state.update { it.copy(stalledIndices = it.stalledIndices + index) }
            val candidate = if (preferences.autoNextChannel.value) nextUntriedIndex(index) else null
            if (candidate == null) {
                _state.update { it.copy(playback = null, errorMessage = message) }
                return
            }
            next = candidate
            _state.update { it.copy(notice = "线路 ${index + 1} 中断，正在尝试线路 ${next + 1}…") }
        }
        val generation = requestGeneration
        recoveryJob?.cancel()
        recoveryJob = scope.launch {
            if (generation == requestGeneration) resolveAndPlay(next, resetStalls = false)
        }
    }

    fun stopPlayback() {
        recoveryJob?.cancel()
        recoveryJob = null
        playbackJob?.cancel()
        requestGeneration += 1
        _state.update { it.copy(resolvingIndex = null, playback = null) }
    }
}
