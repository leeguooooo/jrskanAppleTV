import CommonCrypto
import XCTest
#if os(tvOS)
@testable import JRKANTV
#else
@testable import JRKANiOS
#endif

/// Serves a scripted live stream: each read of a playlist URL returns its
/// next scripted body (the last one repeats), everything else is a fixed file.
private final class ScriptedLoader: HLSLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var playlists: [URL: [String]] = [:]
    private var files: [URL: Data] = [:]
    private(set) var requested: [URL] = []

    func script(_ url: URL, _ bodies: [String]) { lock.withLock { playlists[url] = bodies } }
    func file(_ url: URL, _ data: Data) { lock.withLock { files[url] = data } }

    func load(_ url: URL) async throws -> (Data, URL) {
        try lock.withLock {
            requested.append(url)
            if var bodies = playlists[url], !bodies.isEmpty {
                let body = bodies.count > 1 ? bodies.removeFirst() : bodies[0]
                playlists[url] = bodies
                return (Data(body.utf8), url)
            }
            if let data = files[url] { return (data, url) }
            throw URLError(.fileDoesNotExist)
        }
    }
}

@MainActor
final class RecordingTests: XCTestCase {
    private var root: URL!
    private let base = URL(string: "https://cdn.example/live/")!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Playlist parsing

    func testParsesMasterAndPicksHighestBandwidth() {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2"
        low.m3u8?auth=1
        #EXT-X-STREAM-INF:BANDWIDTH=2560000
        https://edge.example/hd.m3u8?auth=2&sub_m3u8=true
        """
        let playlist = HLSPlaylist.parse(text, baseURL: URL(string: "https://cdn.example/live/master.m3u8?auth=0")!)
        XCTAssertTrue(playlist.isMaster)
        XCTAssertEqual(playlist.variants.first?.url.absoluteString, "https://cdn.example/live/low.m3u8?auth=1")
        XCTAssertEqual(playlist.bestVariant?.url.absoluteString, "https://edge.example/hd.m3u8?auth=2&sub_m3u8=true")
        XCTAssertFalse(playlist.hasSeparateAudio)
    }

    func testDetectsSeparateAudioRendition() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="中文",URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="aud"
        video.m3u8
        """
        XCTAssertTrue(HLSPlaylist.parse(text, baseURL: base).hasSeparateAudio)
    }

    func testParsesLiveMediaPlaylist() {
        let text = """
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
        """
        let playlist = HLSPlaylist.parse(text, baseURL: base.appendingPathComponent("index.m3u8"))
        XCTAssertFalse(playlist.isMaster)
        XCTAssertFalse(playlist.isEnded)
        XCTAssertEqual(playlist.targetDuration, 2)
        XCTAssertEqual(playlist.segments.map(\.sequence), [41, 42, 43])
        XCTAssertEqual(playlist.segments.map(\.duration), [2.0, 1.96, 2.04])
        XCTAssertEqual(playlist.segments[0].url.absoluteString, "https://cdn.example/live/30051626_41.ts?vhost=a&edge_slice=true")
        XCTAssertNil(playlist.segments[0].key)
        XCTAssertEqual(playlist.segments[1].key?.method, .aes128)
        XCTAssertEqual(playlist.segments[1].key?.url?.absoluteString, "https://cdn.example/live/key.bin?t=1")
        XCTAssertEqual(playlist.segments[1].key?.iv, Data(0..<16))
        XCTAssertNil(playlist.segments[2].key)
        XCTAssertTrue(playlist.segments[2].discontinuity)
        XCTAssertEqual(playlist.segments[2].mapURL?.absoluteString, "https://cdn.example/live/init.mp4")
    }

    func testRendersRecordingPlaylist() {
        let entries: [RecordedEntry] = [
            .segment(file: "000001.ts", duration: 2, discontinuity: false),
            .segment(file: "000002.ts", duration: 2.04, discontinuity: false),
            .segment(file: "000003.ts", duration: 2, discontinuity: true)
        ]
        XCTAssertEqual(RecordingPlaylist.parseLog(entries.map(RecordingPlaylist.logLine).joined()), entries)
        XCTAssertEqual(RecordingPlaylist.render(entries, ended: true), """
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

        """)
        XCTAssertTrue(RecordingPlaylist.render(entries, ended: false).contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        XCTAssertFalse(RecordingPlaylist.render(entries, ended: false).contains("#EXT-X-ENDLIST"))
    }

    // MARK: - Recorder

    func testRecordsSlidingWindowAndMarksGap() async throws {
        let loader = ScriptedLoader()
        let master = base.appendingPathComponent("master.m3u8")
        let media = base.appendingPathComponent("media.m3u8")
        loader.script(master, ["#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmedia.m3u8\n"])
        loader.script(media, [
            window(0...2),
            window(1...3),
            window(5...7),           // 4 slid out of the window unseen
            window(7...9, ended: true)
        ])
        for n in 0...9 { loader.file(base.appendingPathComponent("s\(n).ts"), Data("seg-\(n)".utf8)) }

        let (recorder, folder) = try makeRecorder(loader: loader, streamURL: master)
        await recorder.run()

        XCTAssertEqual(recorder.phase, .finished)
        XCTAssertEqual(recorder.info.endReason, "直播已结束")
        XCTAssertEqual(recorder.info.segmentCount, 9)
        XCTAssertEqual(recorder.info.gapCount, 1)
        XCTAssertEqual(recorder.info.duration, 18, accuracy: 0.001)
        let segments = folder.entries().compactMap { entry -> (String, Bool)? in
            if case .segment(let file, _, let gap) = entry { return (file, gap) }
            return nil
        }
        XCTAssertEqual(segments.count, 9)
        XCTAssertEqual(segments.filter(\.1).map(\.0), ["000005.ts"])
        let contents = try segments.map { String(decoding: try Data(contentsOf: folder.url.appendingPathComponent($0.0)), as: UTF8.self) }
        XCTAssertEqual(contents, [0, 1, 2, 3, 5, 6, 7, 8, 9].map { "seg-\($0)" })
        XCTAssertEqual(folder.readInfo()?.endReason, "直播已结束")
        XCTAssertTrue(folder.playlist(ended: true).hasSuffix("#EXT-X-ENDLIST\n"))
    }

    func testDecryptsAES128SegmentsWithSequenceIV() async throws {
        let loader = ScriptedLoader()
        let media = base.appendingPathComponent("media.m3u8")
        let key = Data((0..<16).map { UInt8($0 * 3) })
        loader.script(media, ["""
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:7
        #EXT-X-TARGETDURATION:2
        #EXT-X-KEY:METHOD=AES-128,URI="k.key"
        #EXTINF:2,
        s7.ts
        #EXT-X-ENDLIST
        """])
        loader.file(base.appendingPathComponent("k.key"), key)
        let plain = Data("a transport stream, honest".utf8)
        loader.file(base.appendingPathComponent("s7.ts"), encrypt(plain, key: key, iv: HLSRecorder.sequenceIV(7)))

        let (recorder, folder) = try makeRecorder(loader: loader, streamURL: media)
        await recorder.run()

        XCTAssertEqual(recorder.info.segmentCount, 1)
        XCTAssertEqual(try Data(contentsOf: folder.url.appendingPathComponent("000001.ts")), plain)
    }

    func testReResolvesChannelPageAfterRepeatedFailures() async throws {
        let loader = ScriptedLoader()
        let fresh = base.appendingPathComponent("fresh.m3u8")
        loader.script(fresh, [window(0...1, ended: true)])
        for n in 0...1 { loader.file(base.appendingPathComponent("s\(n).ts"), Data("seg-\(n)".utf8)) }
        var resolved: [URL] = []

        let (recorder, _) = try makeRecorder(loader: loader, streamURL: base.appendingPathComponent("expired.m3u8")) { page in
            resolved.append(page)
            return fresh
        }
        await recorder.run()

        XCTAssertEqual(resolved, [URL(string: "https://site.example/channel-1.html")!])
        XCTAssertEqual(recorder.info.segmentCount, 2)
        XCTAssertEqual(recorder.info.endReason, "直播已结束")
    }

    func testRefusesStreamWithSeparateAudio() async throws {
        let loader = ScriptedLoader()
        let master = base.appendingPathComponent("master.m3u8")
        loader.script(master, ["""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="a"
        video.m3u8
        """])
        let (recorder, _) = try makeRecorder(loader: loader, streamURL: master)
        await recorder.run()
        XCTAssertEqual(recorder.phase, .finished)
        XCTAssertEqual(recorder.info.endReason, RecordingError.separateAudio.localizedDescription)
        XCTAssertEqual(recorder.info.segmentCount, 0)
    }

    func testServerByteRanges() {
        XCTAssertEqual(RecordingServer.byteRange("Range: bytes=0-1", length: 10), 0..<2)
        XCTAssertEqual(RecordingServer.byteRange("Range: bytes=4-", length: 10), 4..<10)
        XCTAssertEqual(RecordingServer.byteRange("Range: bytes=-3", length: 10), 7..<10)
        XCTAssertEqual(RecordingServer.byteRange("Range: bytes=8-99", length: 10), 8..<10)
        XCTAssertNil(RecordingServer.byteRange("Range: bytes=12-", length: 10))
        XCTAssertFalse(RecordingServer.isSafeComponent(".."))
        XCTAssertFalse(RecordingServer.isSafeComponent(""))
        XCTAssertTrue(RecordingServer.isSafeComponent("000001.ts"))
    }

    // MARK: - Helpers

    private func window(_ range: ClosedRange<Int>, ended: Bool = false) -> String {
        var lines = ["#EXTM3U", "#EXT-X-MEDIA-SEQUENCE:\(range.lowerBound)", "#EXT-X-TARGETDURATION:2"]
        for n in range { lines += ["#EXTINF:2.000,", "s\(n).ts"] }
        if ended { lines.append("#EXT-X-ENDLIST") }
        return lines.joined(separator: "\n")
    }

    private func makeRecorder(
        loader: ScriptedLoader,
        streamURL: URL,
        resolve: @escaping (URL) async throws -> URL = { _ in throw URLError(.badServerResponse) }
    ) throws -> (HLSRecorder, RecordingFolder) {
        let store = RecordingStore(root: root)
        let info = RecordingInfo(id: "r1", matchID: "m1", title: "主队 vs 客队", league: "测试联赛",
                                 channelName: "线路一", startedAt: Date())
        let folder = try store.create(info)
        let sources = [MatchSource(id: "c1", name: "线路一", pageURL: URL(string: "https://site.example/channel-1.html")!)]
        let recorder = HLSRecorder(info: info, folder: folder, streamURL: streamURL, sources: sources, sourceIndex: 0,
                                   loader: loader, resolve: resolve, sleep: { _ in }, freeSpace: { nil })
        return (recorder, folder)
    }

    private func encrypt(_ data: Data, key: Data, iv: Data) -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        _ = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, data.count, out.baseAddress, capacity, &written)
                    }
                }
            }
        }
        return output.prefix(written)
    }
}
