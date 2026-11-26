package com.leeguoo.jrkan.state

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.StatFs
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.leeguoo.jrkan.MainActivity
import com.leeguoo.jrkan.R
import com.leeguoo.jrkan.data.Http
import com.leeguoo.jrkan.data.LiveMatch
import com.leeguoo.jrkan.data.ReplayCache
import com.leeguoo.jrkan.data.ReplayParsing
import com.leeguoo.jrkan.data.ReplayStream
import com.leeguoo.jrkan.data.ReplayVideo
import com.leeguoo.jrkan.data.userMessage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream

/** One downloaded (or downloading) recording (ReplayDownload in ReplayDownloads.swift). */
@Serializable
data class ReplayDownload(
    val id: String,
    val video: ReplayVideo,
    val fixture: LiveMatch? = null,
    val label: String,
    val expectedBytes: Long? = null,
    val urlPath: String? = null,
    val totalBytes: Long? = null,
    val receivedBytes: Long = 0,
    val phase: Phase = Phase.Queued,
    val message: String? = null,
    val createdAt: Long = System.currentTimeMillis(),
) {
    @Serializable
    enum class Phase { Queued, Downloading, Paused, Failed, Finished }
}

/**
 * Replay downloads into the app's private files dir (not shared storage, so
 * they never show in the gallery or file managers), for offline viewing.
 * Runs in a foreground service. 64 MB byte ranges; each range asks for a link
 * with 15 minutes left, renewing it on 403; a renewed link must be the same
 * file (path and total size) or the download starts over. Only a 206 whose
 * range starts at the file's current length is appended, and that length is
 * the resume point.
 */
object ReplayDownloads {
    const val CHUNK = 64L shl 20
    private val json = Json { ignoreUnknownKeys = true }
    private val _items = MutableStateFlow<List<ReplayDownload>>(emptyList())
    val items: StateFlow<List<ReplayDownload>> = _items
    /** Bytes written so far, including the range in flight. */
    val liveBytes = MutableStateFlow<Map<String, Long>>(emptyMap())
    private var dir: File? = null
    private lateinit var app: Context

    fun init(context: Context) {
        app = context.applicationContext
        dir = File(context.filesDir, "replay-downloads").apply { mkdirs() }
        _items.value = runCatching {
            json.decodeFromString(ListSerializer(ReplayDownload.serializer()), File(dir, "index.json").readText())
        }.getOrDefault(emptyList()).map { it.copy(receivedBytes = fileSize(it.id)) }
        if (_items.value.any { it.phase == ReplayDownload.Phase.Downloading || it.phase == ReplayDownload.Phase.Queued }) startService()
    }

    fun file(id: String) = File(dir, "$id.mp4")
    fun fileSize(id: String) = file(id).takeIf { it.exists() }?.length() ?: 0L
    fun item(id: String) = _items.value.firstOrNull { it.id == id }
    fun localFile(id: String): File? = item(id)?.takeIf { it.phase == ReplayDownload.Phase.Finished }?.let { file(it.id) }?.takeIf { it.exists() }
    val usedBytes: Long get() = _items.value.sumOf { fileSize(it.id) }

    fun progress(id: String): Float? {
        val item = item(id) ?: return null
        val total = item.totalBytes ?: item.expectedBytes ?: return null
        return ((liveBytes.value[id] ?: item.receivedBytes).toFloat() / total).coerceIn(0f, 1f)
    }

    fun download(video: ReplayVideo, stream: ReplayStream, fixture: LiveMatch?) {
        item(video.id)?.let { if (it.phase != ReplayDownload.Phase.Failed) return }
        file(video.id).delete()
        var entry = ReplayDownload(video.id, video, fixture, stream.label, stream.size, java.net.URI(stream.url).path)
        val free = runCatching { StatFs(dir!!.path).availableBytes }.getOrDefault(Long.MAX_VALUE)
        if (stream.size != null && free < stream.size + (500L shl 20)) {
            entry = entry.copy(phase = ReplayDownload.Phase.Failed, message = "手机存储空间不够")
        }
        _items.update { listOf(entry) + it.filter { other -> other.id != video.id } }
        save()
        if (entry.phase == ReplayDownload.Phase.Queued) startService()
    }

    fun pause(id: String) {
        update(id) { it.copy(phase = ReplayDownload.Phase.Paused, message = null) }
    }

    fun resume(id: String) {
        update(id) { it.copy(phase = ReplayDownload.Phase.Queued, message = null) }
        startService()
    }

    fun delete(id: String) {
        _items.update { list -> list.filter { it.id != id } }
        file(id).delete()
        liveBytes.update { it - id }
        save()
    }

    /** Android 15+: the daily background budget ran out; pause, don't fail. */
    fun pauseAll(message: String) {
        _items.update { list ->
            list.map {
                if (it.phase == ReplayDownload.Phase.Downloading || it.phase == ReplayDownload.Phase.Queued)
                    it.copy(phase = ReplayDownload.Phase.Paused, message = message) else it
            }
        }
        save()
    }

    private fun startService() {
        ContextCompat.startForegroundService(app, Intent(app, ReplayDownloadService::class.java))
    }

    private fun update(id: String, change: (ReplayDownload) -> ReplayDownload) {
        _items.update { list -> list.map { if (it.id == id) change(it) else it } }
        save()
    }

    private fun save() {
        val dir = dir ?: return
        runCatching {
            val tmp = File(dir, "index.json.tmp")
            tmp.writeText(json.encodeToString(ListSerializer(ReplayDownload.serializer()), _items.value))
            tmp.renameTo(File(dir, "index.json"))
        }
    }

    /** The service's loop: oldest queued first, one at a time, until nothing is left. */
    suspend fun run() {
        while (true) {
            val next = _items.value.lastOrNull { it.phase == ReplayDownload.Phase.Downloading || it.phase == ReplayDownload.Phase.Queued } ?: return
            update(next.id) { it.copy(phase = ReplayDownload.Phase.Downloading) }
            downloadAll(next.id)
        }
    }

    private suspend fun downloadAll(id: String) {
        var failures = 0
        var fresh = false
        while (true) {
            val item = item(id) ?: return
            if (item.phase != ReplayDownload.Phase.Downloading) return
            val offset = fileSize(id)
            item.totalBytes?.let { if (offset >= it) { finish(id); return } }
            val outcome = try {
                val stream = link(item, fresh)
                if (item.urlPath != null && item.urlPath != java.net.URI(stream.url).path) {
                    file(id).delete()
                    update(id) { it.copy(urlPath = java.net.URI(stream.url).path, totalBytes = null, receivedBytes = 0, message = "微博换了视频文件，重新下载") }
                    continue
                }
                chunk(id, stream, offset, item.totalBytes)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Outcome.Failed(null, "网络中断：${e.userMessage()}")
            }
            when (outcome) {
                is Outcome.Appended -> {
                    failures = 0; fresh = false
                    val known = item(id)?.totalBytes
                    if (known != null && known != outcome.total) {
                        file(id).delete()
                        update(id) { it.copy(totalBytes = null, receivedBytes = 0, message = "视频文件大小变了，重新下载") }
                        continue
                    }
                    update(id) { it.copy(totalBytes = outcome.total, receivedBytes = fileSize(id)) }
                    liveBytes.update { it - id }
                }
                is Outcome.Failed -> {
                    failures += 1
                    if (outcome.status == 404 || failures > 5) {
                        update(id) { it.copy(phase = ReplayDownload.Phase.Failed, message = if (outcome.status == 404) "这个视频已被删除" else outcome.message) }
                        return
                    }
                    // 403 is an expired link: renew it. Anything else: try again shortly.
                    fresh = outcome.status == 403 || outcome.status == 410 || outcome.status == null
                    delay(minOf(30, failures * failures) * 1000L)
                }
            }
        }
    }

    private fun finish(id: String) {
        update(id) { it.copy(phase = ReplayDownload.Phase.Finished, message = null, receivedBytes = fileSize(id)) }
        liveBytes.update { it - id }
    }

    private suspend fun link(item: ReplayDownload, fresh: Boolean): ReplayStream {
        if (!fresh) {
            ReplayCache.read("streams:${item.id}", ListSerializer(ReplayStream.serializer()))?.value
                ?.firstOrNull { it.label == item.label }
                ?.takeIf { (it.expiresAt ?: 0) - System.currentTimeMillis() > 15 * 60_000L }
                ?.let { return it }
        }
        val streams = ReplayParsing.streams(ReplayLibrary.client.status(item.id))
        ReplayCache.storeStreams(streams, item.id)
        return streams.firstOrNull { it.label == item.label } ?: throw java.io.FileNotFoundException("rendition gone")
    }

    private sealed interface Outcome {
        data class Appended(val total: Long) : Outcome
        data class Failed(val status: Int?, val message: String) : Outcome
    }

    /** One range, appended only if it starts exactly at the file's length. */
    private suspend fun chunk(id: String, stream: ReplayStream, offset: Long, total: Long?): Outcome = withContext(Dispatchers.IO) {
        var end = offset + CHUNK - 1
        if (total != null) end = minOf(end, total - 1)
        // No browser User-Agent: Weibo's CDN 403s a "Mozilla" agent without a weibo.com Referer.
        val request = Request.Builder().url(stream.url).header("Range", "bytes=$offset-$end").build()
        Http.client.newCall(request).execute().use { response ->
            val range = response.header("Content-Range")?.let { Regex("""bytes\s+(\d+)-(\d+)/(\d+)""").find(it) }
            val start = range?.groupValues?.get(1)?.toLongOrNull()
            val fullSize = range?.groupValues?.get(3)?.toLongOrNull()
            if (response.code != 206 || start != offset || fullSize == null || fileSize(id) != offset) {
                return@withContext Outcome.Failed(response.code, "下载出错（${response.code}）")
            }
            // Written to a side file first, appended only when the whole range arrived.
            val part = File(dir, "$id.part")
            response.body.byteStream().use { input ->
                FileOutputStream(part).use { output ->
                    val buffer = ByteArray(256 * 1024)
                    var written = 0L
                    while (true) {
                        if (!coroutineContext.isActive || item(id)?.phase != ReplayDownload.Phase.Downloading) {
                            return@withContext Outcome.Failed(-2, "已暂停")
                        }
                        val n = input.read(buffer)
                        if (n < 0) break
                        output.write(buffer, 0, n)
                        written += n
                        liveBytes.update { it + (id to offset + written) }
                    }
                }
            }
            FileOutputStream(file(id), true).use { out -> part.inputStream().use { it.copyTo(out, 1 shl 20) }; out.fd.sync() }
            part.delete()
            Outcome.Appended(fullSize)
        }
    }
}

/** Keeps downloads going with the screen off or another app open; a progress notification. */
class ReplayDownloadService : Service() {
    private val scope = MainScope()
    private var job: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "回看下载", NotificationManager.IMPORTANCE_LOW).apply { description = "下载回看视频时显示进度。" },
        )
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(), if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0)
        scope.launch {
            while (isActive) {
                getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification())
                delay(2_000)
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (job?.isActive != true) {
            job = scope.launch {
                ReplayDownloads.run()
                ServiceCompat.stopForeground(this@ReplayDownloadService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    /** Android 15+: the daily dataSync budget ran out. Pause, so nothing is lost. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        ReplayDownloads.pauseAll("系统限制了后台下载时长，已暂停，回到应用点继续")
        stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun notification(): Notification {
        val active = ReplayDownloads.items.value.firstOrNull { it.phase == ReplayDownload.Phase.Downloading }
        val percent = active?.let { ((ReplayDownloads.progress(it.id) ?: 0f) * 100).toInt() }
        val open = PendingIntent.getActivity(this, 2, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_record)
            .setContentTitle(active?.let { "正在下载 · ${it.video.displayTitle}" } ?: "正在准备下载")
            .setContentText(percent?.let { "$it% · 仅供个人研究学习，禁止分享传播" } ?: "仅供个人研究学习，禁止分享传播")
            .setProgress(100, percent ?: 0, percent == null)
            .setContentIntent(open)
            .setOngoing(true).setOnlyAlertOnce(true).setSilent(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }


    companion object {
        private const val CHANNEL_ID = "replay-downloads"
        private const val NOTIFICATION_ID = 42
    }
}
