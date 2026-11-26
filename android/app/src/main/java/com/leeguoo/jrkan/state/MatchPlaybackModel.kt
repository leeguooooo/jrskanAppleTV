package com.leeguoo.jrkan.state

import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.MatchSource
import com.leeguoo.jrkan.data.ReplayCache
import com.leeguoo.jrkan.data.ReplayParsing
import com.leeguoo.jrkan.data.ReplayResume
import com.leeguoo.jrkan.data.ReplayVideo
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
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.util.UUID

/** A stream already resolved to a playable URL. */
data class PlaybackRequest(
    val url: String,
    val sourceName: String,
    val index: Int,
    val id: String = UUID.randomUUID().toString(),
    /** Replays: where to start (resume, or after a renewed link). Live starts at the edge. */
    val startAtMs: Long? = null,
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
    val insights: MatchInsightsModel = MatchInsightsModel(),
    /** A replay (回看): the "channels" are one game's uploads (MatchPlaybackModel.swift ReplaySet). */
    val replay: ReplaySet? = null,
) {
    data class ReplaySet(val videos: List<ReplayVideo>, val fixture: LiveMatch?)

    val isReplay: Boolean get() = replay != null

    /** The upload playing (or being opened) now. */
    val currentReplay: ReplayVideo?
        get() {
            val index = _state.value.playback?.index ?: _state.value.resolvingIndex ?: return null
            return replay?.videos?.getOrNull(index)
        }

    private var lastPositionMs = 0L
    private var lastSavedAt = 0L
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
        /** false after the automatic pick (incl. autoplay), true once the viewer picks a channel. */
        val choseManually: Boolean = false,
    )

    private var didOpenMatch = false

    private val _state = MutableStateFlow(State(channels = replay?.let { replaySources(it.videos) }))
    val state: StateFlow<State> = _state

    private var requestGeneration = 0
    private var confirmedRequestId: String? = null
    private var confirmedAt: Long? = null
    private var handledFailureId: String? = null
    private val lastReconnect = mutableMapOf<Int, Long>()
    private var recoveryJob: Job? = null
    private var playbackJob: Job? = null
    private var resolutionMillis = 0L

    // Channels

    /** Parsed channels when the source page gave any, else the homepage entries. */
    val resolvedChannels: List<MatchSource>
        get() = replay?.let { replaySources(it.videos) }
            ?: (_state.value.channels?.takeIf { it.isNotEmpty() } ?: match.sources).sortedBy { it.playbackPriority }

    val isLoadingChannels: Boolean get() = _state.value.channels == null

    val rememberedChannel: MatchSource?
        get() {
            val remembered = preferences.recentWatches.value.firstOrNull { it.id == match.id } ?: return null
            return resolvedChannels.firstOrNull { it.name == remembered.channelName }
        }

    val suggestedChannel: MatchSource?
        get() = preferences.rankedIndices(resolvedChannels, match.id).firstOrNull()?.let { resolvedChannels[it] }

    val automaticFallbackEnabled: Boolean
        get() = !isReplay && preferences.autoNextChannel.value && resolvedChannels.size > 1

    fun subtitle(source: MatchSource, index: Int): String {
        val state = _state.value
        replay?.videos?.getOrNull(index)?.let { video ->
            return if (state.resolvingIndex == index) "正在获取播放地址…" else ReplayVideo.durationText(video.durationSeconds)
        }
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
        val ordered = preferences.rankedIndices(resolvedChannels, match.id)
        return ordered.firstOrNull {
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

    suspend fun openMatch(autoplay: Boolean) {
        if (didOpenMatch) return
        loadChannels()
        currentCoroutineContext().ensureActive()
        didOpenMatch = true
        if (autoplay) startSuggestedPlayback()
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
        _state.update { it.copy(choseManually = false) }
        startPlayback(resolvedChannels.indexOf(source))
    }

    /** A channel the viewer picked from the line menu or the manual list. */
    fun startManualPlayback(index: Int) {
        _state.update { it.copy(choseManually = true) }
        startPlayback(index)
    }

    /** Channel indices in automatic-selection order (read-only view of Preferences.rankedIndices). */
    val rankedIndices: List<Int>
        get() = replay?.videos?.indices?.toList() ?: preferences.rankedIndices(resolvedChannels, match.id)

    // Playback

    fun startPlayback(startIndex: Int, resetStalls: Boolean = true) {
        playbackJob?.cancel()
        playbackJob = scope.launch {
            if (replay != null) startReplay(startIndex, resumeAtMs = null) else resolveAndPlay(startIndex, resetStalls)
        }
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
        if (replay != null) {
            // Nothing to learn about channels, and a replay is not a 最近观看.
            confirmedRequestId = requestId
            confirmedAt = clock()
            return
        }
        val request = _state.value.playback ?: return
        if (request.id != requestId || confirmedRequestId == requestId || request.index !in resolvedChannels.indices) return
        confirmedRequestId = requestId
        confirmedAt = clock()
        preferences.recordPlaybackSuccess(
            match, resolvedChannels[request.index], request.index, resolutionMillis / 1000.0 + startupSeconds,
        )
    }

    /**
     * A confirmed stream gets one same-channel reconnect per two minutes
     * before other sources are tried, and always gets one when it had been
     * playing for a minute: on a weak network every channel hiccups now and
     * then, and hopping only restarts the wait on the same slow connection.
     */
    fun handleStall(message: String, requestId: String? = null, now: Long = clock()) {
        if (replay != null) return handleReplayStall(message, requestId, now)
        val request = _state.value.playback ?: return
        if ((requestId != null && request.id != requestId) || handledFailureId == request.id ||
            request.index !in resolvedChannels.indices
        ) return
        handledFailureId = request.id
        val index = request.index
        preferences.recordPlaybackFailure(resolvedChannels[index], now)
        val playedAWhile = confirmedAt?.let { now - it >= 60_000 } == true
        val shouldReconnect = confirmedRequestId == request.id &&
            (playedAWhile || lastReconnect[index]?.let { now - it >= 120_000 } != false)
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
        currentReplay?.let { ReplayResume.save(lastPositionMs, (it.durationSeconds * 1000).toLong(), it.id) }
        recoveryJob?.cancel()
        recoveryJob = null
        playbackJob?.cancel()
        requestGeneration += 1
        _state.update { it.copy(resolvingIndex = null, playback = null) }
    }

    // Replay

    /** Fetches a fresh MP4 link (they expire in about an hour) and plays it from resumeAtMs, or where it was left. */
    private suspend fun startReplay(index: Int, resumeAtMs: Long?, freshLink: Boolean = false) {
        val replay = replay ?: return
        val video = replay.videos.getOrNull(index) ?: return
        requestGeneration += 1
        val generation = requestGeneration
        if (resumeAtMs == null) {
            recoveryJob?.cancel()
            lastReconnect.clear()
            handledFailureId = null
        }
        _state.update { it.copy(errorMessage = null, resolvingIndex = index) }
        // A downloaded copy plays from disk: no link, no network.
        ReplayDownloads.localFile(video.id)?.let { local ->
            val start = resumeAtMs ?: ReplayResume.positionMs(video.id)
            lastPositionMs = start ?: 0
            confirmedRequestId = null
            _state.update {
                it.copy(playback = PlaybackRequest(android.net.Uri.fromFile(local).toString(), "${video.part.label} · 已下载", index, startAtMs = start),
                    resolvingIndex = null,
                    notice = if (resumeAtMs == null && start != null) "从上次看到的 ${ReplayVideo.durationText(start / 1000.0)} 接着播" else it.notice)
            }
            return
        }
        try {
            // A link with time left is reused; after a failure always get a new one.
            val streams = (if (freshLink) null else ReplayCache.usableStreams(video.id))
                ?: ReplayParsing.streams(ReplayLibrary.client.status(video.id)).also { ReplayCache.storeStreams(it, video.id) }
            if (generation != requestGeneration) return
            val stream = streams.firstOrNull()
            if (stream == null) {
                _state.update { it.copy(playback = null, errorMessage = "这个视频已经看不了了（可能被删除或设为仅粉丝可见）。") }
                return
            }
            val start = resumeAtMs ?: ReplayResume.positionMs(video.id)
            val notice = if (resumeAtMs == null && start != null) "从上次看到的 ${ReplayVideo.durationText(start / 1000.0)} 接着播" else null
            lastPositionMs = start ?: 0
            confirmedRequestId = null
            _state.update {
                it.copy(playback = PlaybackRequest(stream.url, "${video.part.label} · ${video.author}", index, startAtMs = start),
                    notice = notice ?: it.notice)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (generation != requestGeneration) return
            _state.update { it.copy(playback = null, errorMessage = "拿不到播放地址：${e.userMessage()}") }
        } finally {
            if (requestGeneration == generation) _state.update { it.copy(resolvingIndex = null) }
        }
    }

    /** Renew the link and carry on in place; twice in 20 s means the upload is gone. Never hop uploads. */
    private fun handleReplayStall(message: String, requestId: String?, now: Long) {
        val request = _state.value.playback ?: return
        if ((requestId != null && request.id != requestId) || handledFailureId == request.id) return
        handledFailureId = request.id
        // A local file has no link to renew.
        if (request.url.startsWith("file:")) {
            _state.update { it.copy(playback = null, errorMessage = "下载的视频播放失败，可以删掉后重新下载。") }
            return
        }
        val index = request.index
        val last = lastReconnect[index]
        if (last != null && now - last < 20_000) {
            _state.update { it.copy(playback = null, errorMessage = "这个视频一直播放失败，可能已被删除：$message") }
            return
        }
        lastReconnect[index] = now
        _state.update { it.copy(notice = "播放中断，正在换新的播放地址…") }
        val position = lastPositionMs
        recoveryJob?.cancel()
        recoveryJob = scope.launch { startReplay(index, resumeAtMs = position, freshLink = true) }
    }

    /** The player's position, for resuming; saved every few seconds. */
    fun reportPosition(positionMs: Long, durationMs: Long?, now: Long = clock()) {
        val video = currentReplay ?: return
        if (positionMs <= 0) return
        lastPositionMs = positionMs
        if (now - lastSavedAt < 5_000) return
        lastSavedAt = now
        ReplayResume.save(positionMs, durationMs ?: (video.durationSeconds * 1000).toLong(), video.id)
    }

    /** Played to the end: next time it starts from the beginning. */
    fun replayFinished() {
        val video = currentReplay ?: return
        lastPositionMs = 0
        ReplayResume.save(0, null, video.id)
    }

    companion object {
        /** One game's uploads as a player model; fixture orders the teams and feeds 数据 when known. */
        fun replay(videos: List<ReplayVideo>, fixture: LiveMatch?, preferences: Preferences, scope: CoroutineScope): MatchPlaybackModel {
            val first = videos.first()
            val match = LiveMatch(
                id = "replay:${first.matchup?.key ?: first.id}@${first.gameDay}", league = fixture?.league ?: "回看",
                time = fixture?.time ?: "", homeTeam = fixture?.homeTeam ?: first.matchup?.left.orEmpty(),
                awayTeam = fixture?.awayTeam ?: first.matchup?.right.orEmpty(), homeLogoUrl = fixture?.homeLogoUrl,
                awayLogoUrl = fixture?.awayLogoUrl, isHot = false, sources = emptyList(),
            )
            return MatchPlaybackModel(match, preferences, scope, replay = ReplaySet(videos, fixture))
        }

        private fun replaySources(videos: List<ReplayVideo>) =
            videos.map { MatchSource(it.id, "${it.part.label} · ${it.author}", it.shareUrl) }
    }
}
