package com.leeguoo.jrkan.recording

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.OptIn
import androidx.core.content.FileProvider
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import com.google.common.collect.ImmutableList
import com.leeguoo.jrkan.data.AppConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.random.Random

/**
 * Makes the shareable MP4 for a finished recording (RecordingExporter.swift):
 * Media3 Transformer reads the recording's own HLS playlist, draws the
 * watermark (gliding between random spots, cycling its texts) and the
 * `recording_banner` ad into every frame, and re-encodes at about the source
 * bit rate. The result goes to Movies/JRKAN, so the gallery and Files show it.
 */
@OptIn(UnstableApi::class)
object RecordingExporter {
    class Overlay(val watermark: AppConfig.Watermark?, val banner: AppConfig.Slot?)

    /** Runs on the main thread (Transformer needs a Looper); returns the saved video's URI. */
    suspend fun export(
        context: Context,
        info: RecordingInfo,
        playlist: File,
        overlay: Overlay,
        progress: (Double) -> Unit,
    ): Uri {
        val output = File(context.cacheDir, "export-${info.id}.mp4").apply { delete() }
        try {
            transcode(context, playlist, output, overlay, bitRate(info), info.duration, progress)
            return withContext(Dispatchers.IO) { publish(context, output, info.suggestedFileName) }
        } finally {
            output.delete()
        }
    }

    /** About the source's own rate; the overlays add almost nothing. */
    private fun bitRate(info: RecordingInfo): Int {
        if (info.duration <= 0 || info.bytes <= 0) return 3_000_000
        val source = info.bytes * 8 / info.duration
        return (source * 1.1).toInt().coerceIn(1_500_000, 8_000_000)
    }

    private suspend fun transcode(
        context: Context,
        playlist: File,
        output: File,
        overlay: Overlay,
        bitRate: Int,
        duration: Double,
        progress: (Double) -> Unit,
    ) = withContext(Dispatchers.Main) {
        val overlays = buildList<TextureOverlay> {
            overlay.banner?.let { add(BannerOverlay(it)) }
            overlay.watermark?.let { add(WatermarkOverlay(it, duration)) }
        }
        val item = MediaItem.Builder()
            .setUri(Uri.fromFile(playlist))
            .setMimeType(MimeTypes.APPLICATION_M3U8)
            .build()
        val edited = EditedMediaItem.Builder(item)
            .setEffects(Effects(ImmutableList.of(), if (overlays.isEmpty()) ImmutableList.of() else ImmutableList.of(OverlayEffect(overlays))))
            .build()

        suspendCancellableCoroutine { continuation ->
            val transformer = Transformer.Builder(context)
                .setVideoMimeType(MimeTypes.VIDEO_H264)
                .setEncoderFactory(
                    DefaultEncoderFactory.Builder(context)
                        .setRequestedVideoEncoderSettings(VideoEncoderSettings.Builder().setBitrate(bitRate).build())
                        .build()
                )
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        if (continuation.isActive) continuation.resume(Unit)
                    }

                    override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                        if (continuation.isActive) continuation.resumeWithException(exportException)
                    }
                })
                .build()
            transformer.start(edited, output.absolutePath)
            val poller = kotlinx.coroutines.MainScope().launch {
                val holder = ProgressHolder()
                while (continuation.isActive) {
                    if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) progress(holder.progress / 100.0)
                    delay(500)
                }
            }
            continuation.invokeOnCancellation {
                poller.cancel()
                kotlinx.coroutines.MainScope().launch { transformer.cancel() }
            }
            continuation.context[kotlinx.coroutines.Job]?.invokeOnCompletion { poller.cancel() }
        }
    }

    /**
     * Movies/JRKAN through MediaStore on Android 10+, so it shows in the
     * gallery and Files with no storage permission. Older versions keep it in
     * the app's own Movies folder and share it through FileProvider.
     */
    private fun publish(context: Context, file: File, name: String): Uri {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, "$name.mp4")
                put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH, "${Environment.DIRECTORY_MOVIES}/JRKAN")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
                ?: error("无法写入相册")
            try {
                resolver.openOutputStream(uri)!!.use { out -> file.inputStream().use { it.copyTo(out) } }
                resolver.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
            return uri
        }
        val dir = File(context.getExternalFilesDir(Environment.DIRECTORY_MOVIES), "JRKAN").apply { mkdirs() }
        val target = File(dir, "$name.mp4")
        file.copyTo(target, overwrite = true)
        return FileProvider.getUriForFile(context, "${context.packageName}.files", target)
    }

    // MARK: overlays

    /** The watermark: one bitmap per text, the leg's text shown, its position interpolated along the path. */
    private class WatermarkOverlay(private val watermark: AppConfig.Watermark, duration: Double) : BitmapOverlay() {
        private val bitmaps = HashMap<Int, Bitmap>()
        private val legUs = (watermark.interval * 1_000_000).toLong()
        // Normalized device coordinates (-1…1), kept away from the edges.
        private val points = List(((duration / watermark.interval).toInt() + 3).coerceAtLeast(2)) {
            floatArrayOf(Random.nextFloat() * 1.5f - 0.75f, Random.nextFloat() * 1.6f - 0.8f)
        }

        private fun leg(presentationTimeUs: Long) = (presentationTimeUs / legUs).toInt().coerceIn(0, points.size - 2)

        override fun getBitmap(presentationTimeUs: Long): Bitmap {
            val index = leg(presentationTimeUs) % watermark.texts.size
            return bitmaps.getOrPut(index) { textBitmap(watermark.texts[index], watermark.opacity) }
        }

        override fun getOverlaySettings(presentationTimeUs: Long): StaticOverlaySettings {
            val leg = leg(presentationTimeUs)
            val (x, y) = when (watermark.motion) {
                AppConfig.Motion.Fixed -> 0.85f to -0.85f
                AppConfig.Motion.Hop -> points[leg][0] to points[leg][1]
                AppConfig.Motion.Drift -> {
                    val t = ((presentationTimeUs - leg * legUs).toFloat() / legUs).coerceIn(0f, 1f)
                    val a = points[leg]
                    val b = points[leg + 1]
                    (a[0] + (b[0] - a[0]) * t) to (a[1] + (b[1] - a[1]) * t)
                }
            }
            return StaticOverlaySettings.Builder().setBackgroundFrameAnchor(x, y).build()
        }
    }

    /** A dark rounded strip in the bottom-left corner: 推广 tag, title, detail. */
    private class BannerOverlay(slot: AppConfig.Slot) : BitmapOverlay() {
        private val bitmap = bannerBitmap(slot)
        private val settings = StaticOverlaySettings.Builder()
            .setOverlayFrameAnchor(-1f, -1f)
            .setBackgroundFrameAnchor(-0.94f, -0.9f)
            .build()

        override fun getBitmap(presentationTimeUs: Long) = bitmap
        override fun getOverlaySettings(presentationTimeUs: Long) = settings
    }

    // Sized for a 720p frame; Transformer scales overlays with the frame.
    private fun textBitmap(text: String, opacity: Double): Bitmap {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 30f
            typeface = Typeface.DEFAULT_BOLD
            color = Color.argb((opacity * 255).toInt(), 255, 255, 255)
            setShadowLayer(3f, 0f, 1f, Color.argb(160, 0, 0, 0))
        }
        val width = paint.measureText(text).toInt() + 8
        val height = (paint.fontMetrics.bottom - paint.fontMetrics.top).toInt() + 8
        return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
            Canvas(it).drawText(text, 4f, 4f - paint.fontMetrics.top, paint)
        }
    }

    private fun bannerBitmap(slot: AppConfig.Slot): Bitmap {
        val tag = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 18f; color = Color.argb(180, 255, 255, 255) }
        val title = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 22f; typeface = Typeface.DEFAULT_BOLD; color = Color.WHITE }
        val detail = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 18f; color = Color.argb(215, 255, 255, 255) }
        val parts = listOf("推广  " to tag, slot.title to title) + if (slot.detail.isNotEmpty()) listOf("  ${slot.detail}" to detail) else emptyList()
        val padding = 14f
        val textWidth = parts.sumOf { (text, paint) -> paint.measureText(text).toDouble() }.toFloat()
        val height = (title.fontMetrics.bottom - title.fontMetrics.top) + padding * 1.2f
        val bitmap = Bitmap.createBitmap((textWidth + padding * 2).toInt(), height.toInt(), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawRoundRect(RectF(0f, 0f, bitmap.width.toFloat(), bitmap.height.toFloat()), 12f, 12f,
            Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(140, 0, 0, 0) })
        var x = padding
        val baseline = padding * 0.6f - title.fontMetrics.top
        for ((text, paint) in parts) {
            canvas.drawText(text, x, baseline, paint)
            x += paint.measureText(text)
        }
        return bitmap
    }
}
