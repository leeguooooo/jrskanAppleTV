package com.leeguoo.jrkan.recording

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
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.leeguoo.jrkan.MainActivity
import com.leeguoo.jrkan.R
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import java.util.Locale

/**
 * Keeps the process in the foreground while anything records, so recording
 * carries on with the screen off or another app open. The notification shows
 * what is recording and how long, with a stop button. The service stops
 * itself when the last recording ends.
 */
class RecordingService : Service() {
    private val scope = MainScope()
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    @OptIn(ExperimentalCoroutinesApi::class)
    override fun onCreate() {
        super.onCreate()
        createChannel()
        ServiceCompat.startForeground(
            this, NOTIFICATION_ID, notification(emptyList()),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0,
        )
        // Without it the CPU sleeps with the screen off and segments slide out of the live window.
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "jrkan:recording")
            .apply { setReferenceCounted(false); acquire(HlsRecorder.MAXIMUM_DURATION.toLong() * 1000 + 600_000) }

        scope.launch {
            Recordings.active
                .flatMapLatest { active ->
                    if (active.isEmpty()) flowOf(emptyList())
                    else combine(active.values.map { it.info }) { it.toList() }
                }
                .collectLatest { infos ->
                    if (Recordings.active.value.isEmpty()) {
                        ServiceCompat.stopForeground(this@RecordingService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                        stopSelf()
                    } else {
                        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(infos))
                    }
                }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_ALL) Recordings.stopAll("已手动停止")
        // A recording cannot resume after the process dies, so don't restart an empty service.
        return START_NOT_STICKY
    }

    /** Android 15+: the daily dataSync budget ran out. Finish cleanly instead of being killed. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Recordings.stopAll("系统限制后台录制时长，录像已停止")
        stopSelf()
    }

    override fun onDestroy() {
        Recordings.flushAll()
        wakeLock?.takeIf { it.isHeld }?.release()
        scope.cancel()
        super.onDestroy()
    }

    private fun notification(infos: List<RecordingInfo>): Notification {
        val title = when (infos.size) {
            0 -> "正在准备录像"
            1 -> "正在录像 · ${infos[0].title}"
            else -> "正在录制 ${infos.size} 场比赛"
        }
        val text = infos.joinToString("  ") { "${duration(it.duration)} · ${size(it.bytes)}" }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).setAction(MainActivity.ACTION_OPEN_RECORDINGS)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, RecordingService::class.java).setAction(ACTION_STOP_ALL),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_record)
            .setContentTitle(title)
            .setContentText(text.ifEmpty { "录像保存在本机" })
            .setContentIntent(open)
            .addAction(0, "停止录像", stop)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun createChannel() {
        val channel = NotificationChannel(CHANNEL_ID, "录像", NotificationManager.IMPORTANCE_LOW)
            .apply { description = "正在录制比赛时显示，可在这里停止录像。" }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "recording"
        private const val NOTIFICATION_ID = 41
        private const val ACTION_STOP_ALL = "com.leeguoo.jrkan.recording.STOP_ALL"

        fun intent(context: Context) = Intent(context, RecordingService::class.java)

        fun duration(seconds: Double): String {
            val total = seconds.toLong()
            val h = total / 3600
            val m = total / 60 % 60
            val s = total % 60
            return if (h > 0) String.format(Locale.ROOT, "%d:%02d:%02d", h, m, s) else String.format(Locale.ROOT, "%d:%02d", m, s)
        }

        fun size(bytes: Long): String = when {
            bytes >= 1L shl 30 -> String.format(Locale.ROOT, "%.2f GB", bytes / (1L shl 30).toDouble())
            bytes >= 1L shl 20 -> String.format(Locale.ROOT, "%.0f MB", bytes / (1L shl 20).toDouble())
            else -> String.format(Locale.ROOT, "%.0f KB", bytes / 1024.0)
        }
    }
}
