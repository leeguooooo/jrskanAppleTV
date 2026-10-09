package com.leeguoo.jrkan.recording

import android.content.Context
import androidx.core.content.ContextCompat
import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.MatchSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.sample
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * Every recording on this device (RecordingCenter.swift). Independent of
 * [com.leeguoo.jrkan.player.PlayerSession]: closing the player does not stop
 * a recording. While any recording runs, [RecordingService] keeps the process
 * in the foreground so it carries on with the screen off or another app open.
 */
object Recordings {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var appContext: Context
    private lateinit var store: RecordingStore

    private val _recordings = MutableStateFlow<List<RecordingInfo>>(emptyList())
    /** Newest first; running ones carry their live counters. */
    val recordings: StateFlow<List<RecordingInfo>> = _recordings

    private val _active = MutableStateFlow<Map<String, HlsRecorder>>(emptyMap())
    val active: StateFlow<Map<String, HlsRecorder>> = _active

    private val watchers = mutableMapOf<String, Job>()

    fun init(context: Context) {
        if (::appContext.isInitialized) return
        appContext = context.applicationContext
        val root = appContext.getExternalFilesDir("recordings") ?: java.io.File(appContext.filesDir, "recordings")
        store = RecordingStore(root)
        scope.launch { reload(markingInterrupted = true) }
    }

    fun recorderFor(matchId: String): HlsRecorder? =
        _active.value.values.firstOrNull { it.info.value.matchId == matchId && it.phase.value != HlsRecorder.Phase.Finished }

    fun totalBytes(list: List<RecordingInfo>): Long = list.sumOf { it.bytes }

    @OptIn(FlowPreview::class)
    @Synchronized
    fun start(match: LiveMatch, sources: List<MatchSource>, index: Int, streamUrl: String): HlsRecorder? {
        recorderFor(match.id)?.let { return it }
        if (index !in sources.indices) return null
        val info = RecordingInfo(
            id = makeId(),
            matchId = match.id,
            title = "${match.homeTeam} vs ${match.awayTeam}",
            league = match.league,
            channelName = sources[index].name,
            startedAt = System.currentTimeMillis(),
        )
        val folder = store.create(info)
        val recorder = HlsRecorder(info, folder, streamUrl, sources, index, freeSpace = store::availableBytes)
        recorder.onFinish = ::recorderDidFinish
        _active.value = _active.value + (info.id to recorder)
        watchers[info.id] = scope.launch {
            combine(recorder.info, recorder.phase) { _, _ -> }.sample(1_000).collect { reload() }
        }
        recorder.start(scope)
        ContextCompat.startForegroundService(appContext, RecordingService.intent(appContext))
        scope.launch { reload() }
        return recorder
    }

    fun stop(id: String) {
        _active.value[id]?.stop()
    }

    fun delete(id: String) {
        _active.value[id]?.stop()
        scope.launch {
            store.delete(id)
            reload()
        }
    }

    /** The playlist ExoPlayer opens; a running recording plays as a growing EVENT playlist. */
    fun playlistFile(id: String) = store.folder(id).writePlaylist(ended = _active.value[id] == null)

    @Synchronized
    private fun recorderDidFinish(recorder: HlsRecorder) {
        _active.value = _active.value - recorder.id
        watchers.remove(recorder.id)?.cancel()
        scope.launch { reload() }
        // The service watches [active] and stops itself once it is empty.
    }

    private fun reload(markingInterrupted: Boolean = false) {
        val active = _active.value
        _recordings.value = store.list().map { info ->
            active[info.id]?.info?.value ?: if (markingInterrupted && !info.isFinished) {
                // The app was killed mid-recording; the segments are fine.
                info.copy(endedAt = info.startedAt + (info.duration * 1000).toLong(), endReason = "应用被关闭，录像已中断")
                    .also { store.folder(it.id).writeInfo(it) }
            } else {
                info
            }
        }
    }

    /** Android 15 ends dataSync services after 6 hours a day; stop cleanly when told. */
    fun stopAll(reason: String) {
        _active.value.values.forEach { it.stop(reason) }
    }

    fun flushAll() {
        _active.value.values.forEach { runCatching { it.flushInfo() } }
    }

    private fun makeId(): String =
        SimpleDateFormat("yyyyMMdd-HHmmss", Locale.ROOT).format(Date()) + "-" + UUID.randomUUID().toString().take(6)
}
