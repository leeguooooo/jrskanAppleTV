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
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withContext
import android.net.Uri
import com.leeguoo.jrkan.state.AppConfigStore
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

    /** MP4 export progress (0…1) per recording, and failures to retry. */
    private val _exporting = MutableStateFlow<Map<String, Double>>(emptyMap())
    val exporting: StateFlow<Map<String, Double>> = _exporting
    private val _exportErrors = MutableStateFlow<Map<String, String>>(emptyMap())
    val exportErrors: StateFlow<Map<String, String>> = _exportErrors
    private val exportQueue = Channel<String>(Channel.UNLIMITED)
    private val queued = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    fun init(context: Context) {
        if (::appContext.isInitialized) return
        appContext = context.applicationContext
        // Segments are scratch until the MP4 lands in Movies/JRKAN; keep them private.
        val root = java.io.File(appContext.filesDir, "recordings")
        store = RecordingStore(root)
        scope.launch {
            reload(markingInterrupted = true)
            exportPending()
        }
        // One export at a time, on the main thread (Transformer needs a Looper).
        MainScope().launch { for (id in exportQueue) runExport(id) }
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
            store.folder(id).readInfo()?.videoUri?.let { uri ->
                runCatching { appContext.contentResolver.delete(Uri.parse(uri), null, null) }
            }
            store.delete(id)
            reload()
        }
    }

    // MARK: MP4 export

    /** The saved MP4, if it still exists (the viewer may have deleted it in the gallery). */
    fun videoUri(info: RecordingInfo): Uri? {
        val uri = info.videoUri?.let(Uri::parse) ?: return null
        return uri.takeIf {
            runCatching { appContext.contentResolver.openFileDescriptor(it, "r")?.use { true } ?: false }.getOrDefault(false)
        }
    }

    fun export(id: String) {
        if (!queued.add(id)) return
        _exportErrors.value = _exportErrors.value - id
        exportQueue.trySend(id)
    }

    private fun exportPending() {
        for (info in _recordings.value) {
            if (info.isFinished && info.videoUri == null && info.id !in _active.value && store.folder(info.id).hasSegments) export(info.id)
        }
    }

    private suspend fun runExport(id: String) {
        try {
            val folder = store.folder(id)
            val info = folder.readInfo() ?: return
            if (info.videoUri != null || !folder.hasSegments) return
            _exporting.value = _exporting.value + (id to 0.0)
            ContextCompat.startForegroundService(appContext, RecordingService.intent(appContext))
            val config = AppConfigStore.config.value
            val member = AppConfigStore.isMember.value
            val overlay = RecordingExporter.Overlay(config.visibleWatermark(member), config.slot("recording_banner", member))
            val playlist = withContext(Dispatchers.IO) { folder.writePlaylist(ended = true) }
            val uri = RecordingExporter.export(appContext, info, playlist, overlay) { value ->
                if (id in _exporting.value) _exporting.value = _exporting.value + (id to value)
            }
            withContext(Dispatchers.IO) {
                folder.writeInfo(info.copy(videoUri = uri.toString()))
                folder.removeMedia()
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _exportErrors.value = _exportErrors.value + (id to "生成视频失败：${e.message ?: e.javaClass.simpleName}")
        } finally {
            queued.remove(id)
            _exporting.value = _exporting.value - id
            scope.launch { reload() }
        }
    }

    /** What the player opens: the MP4 when made, else the playlist (a running one grows as an EVENT playlist). */
    fun playbackUri(info: RecordingInfo): Uri =
        videoUri(info) ?: Uri.fromFile(store.folder(info.id).writePlaylist(ended = _active.value[info.id] == null))

    @Synchronized
    private fun recorderDidFinish(recorder: HlsRecorder) {
        _active.value = _active.value - recorder.id
        watchers.remove(recorder.id)?.cancel()
        scope.launch { reload() }
        if (recorder.info.value.segmentCount > 0) export(recorder.id)
        // The service watches [active] and [exporting] and stops once both are empty.
    }

    private fun reload(markingInterrupted: Boolean = false) {
        val active = _active.value
        // An MP4 deleted in the gallery, with no segments left: nothing to keep.
        val listed = store.list().filter { info ->
            val gone = info.videoUri != null && !store.folder(info.id).hasSegments && videoUri(info) == null
            if (gone) store.delete(info.id)
            !gone
        }
        _recordings.value = listed.map { info ->
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
