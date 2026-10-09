package com.leeguoo.jrkan.recording

import com.leeguoo.jrkan.data.HlsPlaylist
import com.leeguoo.jrkan.data.Http
import com.leeguoo.jrkan.data.MatchSource
import com.leeguoo.jrkan.data.RecordedEntry
import com.leeguoo.jrkan.data.StreamResolver
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.util.Locale
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

class RecordingException(val kind: Kind, detail: String = "") : Exception(kind.message(detail)) {
    enum class Kind(val fatal: Boolean) {
        BadStatus(false), EmptyPlaylist(false), SeparateAudio(true), UnsupportedEncryption(true), DecryptionFailed(true);

        fun message(detail: String): String = when (this) {
            BadStatus -> "直播源返回 HTTP $detail。"
            EmptyPlaylist -> "直播源暂时没有新的画面。"
            SeparateAudio -> "这条线路的声音和画面分开传输，暂不支持录像。"
            UnsupportedEncryption -> "这条线路使用 $detail 加密，暂不支持录像。"
            DecryptionFailed -> "这条线路的视频无法解密，录像已停止。"
        }
    }
}

/** Fetches playlists, segments and keys: body plus the URL after redirects. */
fun interface HlsLoader {
    suspend fun load(url: String): Pair<ByteArray, String>
}

object OkHttpHlsLoader : HlsLoader {
    override suspend fun load(url: String): Pair<ByteArray, String> {
        val page = Http.get(url, timeoutSeconds = 15)
        if (page.status !in 200..299) throw RecordingException(RecordingException.Kind.BadStatus, page.status.toString())
        return page.body to page.finalUrl
    }
}

/**
 * Records one live HLS stream to disk (HLSRecorder.swift). Re-reads the live
 * playlist every half target duration, fetches unseen segments, decrypts
 * AES-128 ones and appends them to the log. Missed segments, a reconnect or a
 * channel switch become a discontinuity. A stream that keeps failing is
 * re-resolved from its channel page, then from the match's other channels.
 */
class HlsRecorder(
    initialInfo: RecordingInfo,
    private val folder: RecordingFolder,
    private var streamUrl: String?,
    val sources: List<MatchSource>,
    sourceIndex: Int,
    private val loader: HlsLoader = OkHttpHlsLoader,
    private val resolve: suspend (String) -> String = { StreamResolver().resolve(it) },
    private val sleep: suspend (Double) -> Unit = { delay((it * 1000).toLong()) },
    private val freeSpace: () -> Long? = { null },
) {
    enum class Phase { Recording, Reconnecting, Finished }

    val id: String = initialInfo.id
    private val _info = MutableStateFlow(initialInfo)
    val info: StateFlow<RecordingInfo> = _info
    private val _phase = MutableStateFlow(Phase.Recording)
    val phase: StateFlow<Phase> = _phase
    private val _sourceIndex = MutableStateFlow(sourceIndex)
    val sourceIndex: StateFlow<Int> = _sourceIndex

    var onFinish: ((HlsRecorder) -> Unit)? = null

    @Volatile private var pendingSource: Int? = null
    private var job: Job? = null

    private val finished get() = _phase.value == Phase.Finished

    fun start(scope: CoroutineScope) {
        if (job == null) job = scope.launch { run() }
    }

    /** Ends the recording now; what is on disk stays playable. */
    fun stop(reason: String = "已手动停止") {
        job?.cancel()
        finish(reason)
    }

    fun switchSource(index: Int) {
        if (index in sources.indices && !finished) pendingSource = index
    }

    fun flushInfo() = folder.writeInfo(_info.value)

    /** Runs the loop to completion. Exposed for tests; the app calls [start]. */
    suspend fun run() {
        var lastSequence: Int? = null
        val recentPaths = ArrayDeque<String>()
        var discontinuity = false
        var failures = 0
        var resolveRounds = 0
        var currentMap: String? = null
        val keys = mutableMapOf<String, ByteArray>()

        while (currentCoroutineContext().isActive && !finished) {
            pendingSource?.let { index ->
                pendingSource = null
                _sourceIndex.value = index
                _info.update { it.copy(channelName = sources[index].name) }
                streamUrl = null
                lastSequence = null
                discontinuity = true
            }
            if (_info.value.duration >= MAXIMUM_DURATION) return finish("已录满 5 小时，自动停止")
            freeSpace()?.let { if (it < MINIMUM_FREE_BYTES) return finish("存储空间不足，已自动停止") }

            val failure: Exception? = try {
                val mediaUrl = streamUrl ?: run {
                    _phase.value = Phase.Reconnecting
                    resolveStream().also { streamUrl = it }
                }
                val (body, finalUrl) = loader.load(mediaUrl)
                if (finished) return
                val playlist = HlsPlaylist.parse(String(body, Charsets.UTF_8), finalUrl)

                if (playlist.isMaster) {
                    if (playlist.hasSeparateAudio) throw RecordingException(RecordingException.Kind.SeparateAudio)
                    streamUrl = playlist.bestVariant?.url
                    continue
                }
                if (playlist.segments.isEmpty() && !playlist.isEnded) throw RecordingException(RecordingException.Kind.EmptyPlaylist)
                failures = 0
                resolveRounds = 0
                _phase.value = Phase.Recording

                // A live window that jumps backwards is a restarted stream.
                val newest = playlist.segments.lastOrNull()?.sequence ?: 0
                val last = lastSequence
                val restarted = last != null && newest < last - 3
                val fresh = playlist.segments.filter { segment ->
                    HlsPlaylist.path(segment.url) !in recentPaths && (restarted || last == null || segment.sequence > last)
                }
                if (restarted) discontinuity = true
                val first = fresh.firstOrNull()
                if (last != null && first != null && !restarted && first.sequence > last + 1) {
                    discontinuity = true
                    _info.update { it.copy(gapCount = it.gapCount + 1) }
                }

                for (batch in fresh.chunked(2)) {
                    val results = download(batch)
                    if (finished) return
                    for ((segment, result) in batch.zip(results)) {
                        lastSequence = segment.sequence
                        recentPaths.addLast(HlsPlaylist.path(segment.url))
                        while (recentPaths.size > 64) recentPaths.removeFirst()
                        val bytes = result.getOrNull()
                        if (bytes != null) {
                            store(segment, bytes, discontinuity, keys, currentMap)?.let { currentMap = it }
                            discontinuity = false
                        } else {
                            if (!discontinuity) _info.update { it.copy(gapCount = it.gapCount + 1) }
                            discontinuity = true
                        }
                    }
                }

                if (playlist.isEnded) return finish("直播已结束")
                sleep(maxOf(1.0, playlist.targetDuration / 2))
                null
            } catch (e: CancellationException) {
                throw e
            } catch (e: RecordingException) {
                if (e.kind.fatal) return finish(e.message ?: "录像已停止")
                e
            } catch (e: Exception) {
                e
            }

            if (failure != null) {
                if (finished) return
                failures += 1
                _phase.value = Phase.Reconnecting
                if (failures >= FAILURES_BEFORE_RESOLVE) {
                    failures = 0
                    resolveRounds += 1
                    if (resolveRounds > RESOLVE_ROUNDS_BEFORE_GIVING_UP) return finish("直播源长时间无法连接，录像已结束")
                    streamUrl = null
                    lastSequence = null
                    if (!discontinuity) _info.update { it.copy(gapCount = it.gapCount + 1) }
                    discontinuity = true
                }
                sleep(3.0)
            }
        }
    }

    /** The recorded channel first, then the others in list order. */
    private suspend fun resolveStream(): String {
        val current = _sourceIndex.value
        var lastError: Exception = RecordingException(RecordingException.Kind.EmptyPlaylist)
        for (index in listOf(current) + sources.indices.filter { it != current }) {
            try {
                val url = resolve(sources[index].pageUrl)
                if (index != current) {
                    _sourceIndex.value = index
                    _info.update { it.copy(channelName = sources[index].name) }
                }
                return url
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                lastError = e
            }
        }
        throw lastError
    }

    private suspend fun download(segments: List<HlsPlaylist.Segment>): List<Result<ByteArray>> = coroutineScope {
        segments.map { segment ->
            async {
                try {
                    Result.success(loader.load(segment.url).first)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Result.failure(e)
                }
            }
        }.awaitAll()
    }

    /** Writes one segment; returns the init-segment URL now in effect when it changed. */
    private suspend fun store(
        segment: HlsPlaylist.Segment,
        bytes: ByteArray,
        discontinuity: Boolean,
        keys: MutableMap<String, ByteArray>,
        currentMap: String?,
    ): String? {
        var payload = bytes
        segment.key?.let { key ->
            when (val method = key.method) {
                is HlsPlaylist.Key.Method.Unsupported ->
                    throw RecordingException(RecordingException.Kind.UnsupportedEncryption, method.name)
                HlsPlaylist.Key.Method.Aes128 -> {
                    val keyUrl = key.url ?: throw RecordingException(RecordingException.Kind.DecryptionFailed)
                    val keyBytes = keys.getOrPut(keyUrl) { loader.load(keyUrl).first }
                    payload = decryptAes128(payload, keyBytes, key.iv ?: sequenceIv(segment.sequence))
                        ?: throw RecordingException(RecordingException.Kind.DecryptionFailed)
                }
            }
        }

        val number = _info.value.segmentCount + 1
        var newMap: String? = null
        var mapBytes = 0
        val mapUrl = segment.mapUrl
        if (mapUrl != null && mapUrl != currentMap) {
            val data = loader.load(mapUrl).first
            val name = String.format(Locale.ROOT, "init-%06d.mp4", number)
            folder.writeFile(name, data)
            folder.append(RecordedEntry.Map(name))
            newMap = mapUrl
            mapBytes = data.size
        }

        val name = String.format(Locale.ROOT, "%06d.%s", number, fileExtension(segment.url))
        folder.writeFile(name, payload)
        folder.append(RecordedEntry.Segment(name, segment.duration, discontinuity))
        _info.update {
            it.copy(
                segmentCount = number,
                duration = it.duration + segment.duration,
                bytes = it.bytes + payload.size + mapBytes,
            )
        }
        if (number % 5 == 1) folder.writeInfo(_info.value)
        return newMap
    }

    @Synchronized
    private fun finish(reason: String) {
        if (finished) return
        _info.update { it.copy(endedAt = System.currentTimeMillis(), endReason = reason) }
        _phase.value = Phase.Finished
        runCatching { folder.writeInfo(_info.value) }
        onFinish?.invoke(this)
    }

    companion object {
        const val MINIMUM_FREE_BYTES = 500L * 1024 * 1024
        const val MAXIMUM_DURATION = 5 * 3600.0
        const val FAILURES_BEFORE_RESOLVE = 5
        const val RESOLVE_ROUNDS_BEFORE_GIVING_UP = 40

        fun fileExtension(url: String): String {
            val ext = HlsPlaylist.path(url).substringAfterLast('/').substringAfterLast('.', "").lowercase(Locale.ROOT)
            return if (ext in setOf("ts", "m4s", "mp4", "m4v", "aac", "m4a")) ext else "ts"
        }

        /** AES-128 HLS without an IV attribute uses the media sequence number, big-endian. */
        fun sequenceIv(sequence: Int): ByteArray =
            ByteArray(16).also { iv -> for (i in 0 until 8) iv[15 - i] = (sequence.toLong() ushr (8 * i)).toByte() }

        fun decryptAes128(data: ByteArray, key: ByteArray, iv: ByteArray): ByteArray? = runCatching {
            Cipher.getInstance("AES/CBC/PKCS5Padding").run {
                init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
                doFinal(data)
            }
        }.getOrNull()
    }
}
