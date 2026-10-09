package com.leeguoo.jrkan.recording

import com.leeguoo.jrkan.data.RecordedEntry
import com.leeguoo.jrkan.data.RecordingPlaylist
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/** What the recordings list shows about one recording (RecordingStore.swift). */
@Serializable
data class RecordingInfo(
    val id: String,
    val matchId: String,
    val title: String,
    val league: String,
    val channelName: String,
    /** Epoch milliseconds. */
    val startedAt: Long,
    val endedAt: Long? = null,
    val duration: Double = 0.0,
    val bytes: Long = 0,
    val segmentCount: Int = 0,
    /** Stretches the recorder could not fetch; playback jumps over them. */
    val gapCount: Int = 0,
    val endReason: String? = null,
    /** The shareable MP4 (a MediaStore or FileProvider URI) once made; the segments are deleted then. */
    val videoUri: String? = null,
) {
    val isFinished: Boolean get() = endedAt != null

    /** "10月9日 1715 湖人 vs 勇士", safe as a file name. */
    val suggestedFileName: String
        get() = (java.text.SimpleDateFormat("M月d日 HHmm", java.util.Locale.CHINA).format(java.util.Date(startedAt)) + " " + title)
            .replace(Regex("[/\\\\:?*\"<>|]"), "-")
}

/** One recording's folder: `info.json`, the append-only `segments.log` and the media it names. */
class RecordingFolder(val dir: File) {
    private val infoFile get() = File(dir, "info.json")
    private val logFile get() = File(dir, "segments.log")
    val playlistFile get() = File(dir, "index.m3u8")

    fun readInfo(): RecordingInfo? = runCatching { json.decodeFromString<RecordingInfo>(infoFile.readText()) }.getOrNull()

    fun writeInfo(info: RecordingInfo) {
        val tmp = File(dir, "info.json.tmp")
        tmp.writeText(json.encodeToString(info))
        tmp.renameTo(infoFile)
    }

    fun writeFile(name: String, bytes: ByteArray) = File(dir, name).writeBytes(bytes)

    fun append(entry: RecordedEntry) = logFile.appendText(RecordingPlaylist.logLine(entry))

    fun entries(): List<RecordedEntry> =
        if (logFile.exists()) RecordingPlaylist.parseLog(logFile.readText()) else emptyList()

    fun playlist(ended: Boolean): String = RecordingPlaylist.render(entries(), ended)

    val hasSegments: Boolean get() = logFile.exists()

    /** Everything but info.json, once the MP4 exists. */
    fun removeMedia() {
        dir.listFiles()?.filter { it.name != "info.json" }?.forEach { it.deleteRecursively() }
    }

    /** ExoPlayer reads the playlist from disk; refresh it before each playback. */
    fun writePlaylist(ended: Boolean): File = playlistFile.also { it.writeText(playlist(ended)) }

    companion object {
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    }
}

/**
 * Recordings live in the app's private files dir until their MP4 is made:
 * removed with the app, not part of any backup (allowBackup is off).
 */
class RecordingStore(val root: File) {
    fun folder(id: String) = RecordingFolder(File(root, id))

    fun create(info: RecordingInfo): RecordingFolder {
        val folder = folder(info.id)
        folder.dir.mkdirs()
        folder.writeInfo(info)
        return folder
    }

    /** Newest first. */
    fun list(): List<RecordingInfo> =
        (root.listFiles()?.toList() ?: emptyList())
            .mapNotNull { if (it.isDirectory) folder(it.name).readInfo() else null }
            .sortedByDescending { it.startedAt }

    fun delete(id: String) {
        folder(id).dir.deleteRecursively()
    }

    fun availableBytes(): Long? {
        root.mkdirs()
        return root.usableSpace.takeIf { it > 0 }
    }
}
