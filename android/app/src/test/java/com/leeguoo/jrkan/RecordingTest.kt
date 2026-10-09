package com.leeguoo.jrkan

import com.leeguoo.jrkan.data.HlsPlaylist
import com.leeguoo.jrkan.data.MatchSource
import com.leeguoo.jrkan.data.RecordedEntry
import com.leeguoo.jrkan.data.RecordingPlaylist
import com.leeguoo.jrkan.recording.HlsLoader
import com.leeguoo.jrkan.recording.HlsRecorder
import com.leeguoo.jrkan.recording.RecordingException
import com.leeguoo.jrkan.recording.RecordingFolder
import com.leeguoo.jrkan.recording.RecordingInfo
import com.leeguoo.jrkan.recording.RecordingStore
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Port of App/Tests/RecordingTests.swift. */
class RecordingTest {
    private val root: File = Files.createTempDirectory("rec").toFile()
    private val base = "https://cdn.example/live/"

    @After
    fun cleanUp() {
        root.deleteRecursively()
    }

    /** Each read of a playlist URL returns its next scripted body (the last repeats). */
    private class ScriptedLoader : HlsLoader {
        val playlists = mutableMapOf<String, ArrayDeque<String>>()
        val files = mutableMapOf<String, ByteArray>()

        fun script(url: String, vararg bodies: String) {
            playlists[url] = ArrayDeque(bodies.toList())
        }

        override suspend fun load(url: String): Pair<ByteArray, String> = synchronized(this) {
            playlists[url]?.let { bodies ->
                val body = if (bodies.size > 1) bodies.removeFirst() else bodies.first()
                return body.toByteArray() to url
            }
            files[url]?.let { return it to url }
            throw IOException("no fixture for $url")
        }
    }

    // MARK: playlist parsing

    @Test
    fun parsesMasterAndPicksHighestBandwidth() {
        val text = """
            #EXTM3U
            #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2"
            low.m3u8?auth=1
            #EXT-X-STREAM-INF:BANDWIDTH=2560000
            https://edge.example/hd.m3u8?auth=2&sub_m3u8=true
        """.trimIndent()
        val playlist = HlsPlaylist.parse(text, "https://cdn.example/live/master.m3u8?auth=0")
        assertTrue(playlist.isMaster)
        assertEquals("https://cdn.example/live/low.m3u8?auth=1", playlist.variants.first().url)
        assertEquals("https://edge.example/hd.m3u8?auth=2&sub_m3u8=true", playlist.bestVariant?.url)
        assertFalse(playlist.hasSeparateAudio)
    }

    @Test
    fun detectsSeparateAudioRendition() {
        val text = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="中文",URI="audio.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="aud"
            video.m3u8
        """.trimIndent()
        assertTrue(HlsPlaylist.parse(text, base).hasSeparateAudio)
    }

    @Test
    fun parsesLiveMediaPlaylist() {
        val text = """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-MEDIA-SEQUENCE:41
            #EXT-X-TARGETDURATION:2
            #EXTINF:2.000,
            30051626_41.ts?vhost=a&edge_slice=true
            #EXT-X-KEY:METHOD=AES-128,URI="key.bin?t=1",IV=0x000102030405060708090a0b0c0d0e0f
            #EXTINF:1.960,
            30051626_42.ts?vhost=a&edge_slice=true
            #EXT-X-DISCONTINUITY
            #EXT-X-KEY:METHOD=NONE
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:2.040,title
            43.m4s
        """.trimIndent()
        val playlist = HlsPlaylist.parse(text, base + "index.m3u8")
        assertFalse(playlist.isMaster)
        assertFalse(playlist.isEnded)
        assertEquals(2.0, playlist.targetDuration, 0.0)
        assertEquals(listOf(41, 42, 43), playlist.segments.map { it.sequence })
        assertEquals(listOf(2.0, 1.96, 2.04), playlist.segments.map { it.duration })
        assertEquals("https://cdn.example/live/30051626_41.ts?vhost=a&edge_slice=true", playlist.segments[0].url)
        assertNull(playlist.segments[0].key)
        assertEquals(HlsPlaylist.Key.Method.Aes128, playlist.segments[1].key?.method)
        assertEquals("https://cdn.example/live/key.bin?t=1", playlist.segments[1].key?.url)
        assertArrayEquals(ByteArray(16) { it.toByte() }, playlist.segments[1].key?.iv)
        assertNull(playlist.segments[2].key)
        assertTrue(playlist.segments[2].discontinuity)
        assertEquals("https://cdn.example/live/init.mp4", playlist.segments[2].mapUrl)
    }

    @Test
    fun rendersRecordingPlaylist() {
        val entries = listOf(
            RecordedEntry.Segment("000001.ts", 2.0, false),
            RecordedEntry.Segment("000002.ts", 2.04, false),
            RecordedEntry.Segment("000003.ts", 2.0, true),
        )
        assertEquals(entries, RecordingPlaylist.parseLog(entries.joinToString("") { RecordingPlaylist.logLine(it) }))
        assertEquals(
            """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:3
            #EXT-X-MEDIA-SEQUENCE:0
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXTINF:2.000,
            000001.ts
            #EXTINF:2.040,
            000002.ts
            #EXT-X-DISCONTINUITY
            #EXTINF:2.000,
            000003.ts
            #EXT-X-ENDLIST

            """.trimIndent(),
            RecordingPlaylist.render(entries, ended = true),
        )
        assertTrue(RecordingPlaylist.render(entries, ended = false).contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        assertFalse(RecordingPlaylist.render(entries, ended = false).contains("#EXT-X-ENDLIST"))
    }

    // MARK: recorder

    @Test
    fun recordsSlidingWindowAndMarksGap() = runBlocking {
        val loader = ScriptedLoader()
        loader.script(base + "master.m3u8", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmedia.m3u8\n")
        loader.script(
            base + "media.m3u8",
            window(0..2), window(1..3),
            window(5..7), // 4 slid out of the window unseen
            window(7..9, ended = true),
        )
        for (n in 0..9) loader.files[base + "s$n.ts"] = "seg-$n".toByteArray()

        val (recorder, folder) = makeRecorder(loader, base + "master.m3u8")
        recorder.run()

        val info = recorder.info.value
        assertEquals(HlsRecorder.Phase.Finished, recorder.phase.value)
        assertEquals("直播已结束", info.endReason)
        assertEquals(9, info.segmentCount)
        assertEquals(1, info.gapCount)
        assertEquals(18.0, info.duration, 0.001)
        val segments = folder.entries().filterIsInstance<RecordedEntry.Segment>()
        assertEquals(listOf("000005.ts"), segments.filter { it.discontinuity }.map { it.file })
        assertEquals(
            listOf(0, 1, 2, 3, 5, 6, 7, 8, 9).map { "seg-$it" },
            segments.map { File(folder.dir, it.file).readText() },
        )
        assertEquals("直播已结束", folder.readInfo()?.endReason)
        assertTrue(folder.playlist(ended = true).endsWith("#EXT-X-ENDLIST\n"))
    }

    @Test
    fun decryptsAes128SegmentsWithSequenceIv() = runBlocking {
        val loader = ScriptedLoader()
        val key = ByteArray(16) { (it * 3).toByte() }
        loader.script(
            base + "media.m3u8",
            """
            #EXTM3U
            #EXT-X-MEDIA-SEQUENCE:7
            #EXT-X-TARGETDURATION:2
            #EXT-X-KEY:METHOD=AES-128,URI="k.key"
            #EXTINF:2,
            s7.ts
            #EXT-X-ENDLIST
            """.trimIndent(),
        )
        loader.files[base + "k.key"] = key
        val plain = "a transport stream, honest".toByteArray()
        loader.files[base + "s7.ts"] = Cipher.getInstance("AES/CBC/PKCS5Padding").run {
            init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), IvParameterSpec(HlsRecorder.sequenceIv(7)))
            doFinal(plain)
        }

        val (recorder, folder) = makeRecorder(loader, base + "media.m3u8")
        recorder.run()

        assertEquals(1, recorder.info.value.segmentCount)
        assertArrayEquals(plain, File(folder.dir, "000001.ts").readBytes())
    }

    @Test
    fun reResolvesChannelPageAfterRepeatedFailures() = runBlocking {
        val loader = ScriptedLoader()
        loader.script(base + "fresh.m3u8", window(0..1, ended = true))
        for (n in 0..1) loader.files[base + "s$n.ts"] = "seg-$n".toByteArray()
        val resolved = mutableListOf<String>()

        val (recorder, _) = makeRecorder(loader, base + "expired.m3u8") { page ->
            resolved += page
            base + "fresh.m3u8"
        }
        recorder.run()

        assertEquals(listOf("https://site.example/channel-1.html"), resolved)
        assertEquals(2, recorder.info.value.segmentCount)
        assertEquals("直播已结束", recorder.info.value.endReason)
    }

    @Test
    fun refusesStreamWithSeparateAudio() = runBlocking {
        val loader = ScriptedLoader()
        loader.script(
            base + "master.m3u8",
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="a"
            video.m3u8
            """.trimIndent(),
        )
        val (recorder, _) = makeRecorder(loader, base + "master.m3u8")
        recorder.run()
        assertEquals(HlsRecorder.Phase.Finished, recorder.phase.value)
        assertEquals(RecordingException.Kind.SeparateAudio.message(""), recorder.info.value.endReason)
        assertEquals(0, recorder.info.value.segmentCount)
    }

    // MARK: helpers

    private fun window(range: IntRange, ended: Boolean = false): String {
        val lines = mutableListOf("#EXTM3U", "#EXT-X-MEDIA-SEQUENCE:${range.first}", "#EXT-X-TARGETDURATION:2")
        for (n in range) lines += listOf("#EXTINF:2.000,", "s$n.ts")
        if (ended) lines += "#EXT-X-ENDLIST"
        return lines.joinToString("\n")
    }

    private fun makeRecorder(
        loader: ScriptedLoader,
        streamUrl: String,
        resolve: suspend (String) -> String = { throw IOException("no resolver") },
    ): Pair<HlsRecorder, RecordingFolder> {
        val store = RecordingStore(root)
        val info = RecordingInfo("r1", "m1", "主队 vs 客队", "测试联赛", "线路一", System.currentTimeMillis())
        val folder = store.create(info)
        val sources = listOf(MatchSource("c1", "线路一", "https://site.example/channel-1.html"))
        val recorder = HlsRecorder(info, folder, streamUrl, sources, 0, loader, resolve, sleep = {}, freeSpace = { null })
        return recorder to folder
    }
}
