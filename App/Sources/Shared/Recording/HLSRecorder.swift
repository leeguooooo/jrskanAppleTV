import CommonCrypto
import Foundation

enum RecordingError: LocalizedError, Equatable {
    case badStatus(Int)
    case emptyPlaylist
    case separateAudio
    case unsupportedEncryption(String)
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "直播源返回 HTTP \(code)。"
        case .emptyPlaylist: return "直播源暂时没有新的画面。"
        case .separateAudio: return "这条线路的声音和画面分开传输，暂不支持录像。"
        case .unsupportedEncryption(let method): return "这条线路使用 \(method) 加密，暂不支持录像。"
        case .decryptionFailed: return "这条线路的视频无法解密，录像已停止。"
        }
    }

    /// Errors no reconnect will fix.
    var isFatal: Bool {
        switch self {
        case .separateAudio, .unsupportedEncryption, .decryptionFailed: return true
        case .badStatus, .emptyPlaylist: return false
        }
    }
}

/// Fetches playlists, segments and keys. A protocol so tests can serve a
/// scripted live window without a network.
protocol HLSLoading: Sendable {
    /// The body and the URL after redirects (relative segment URLs resolve
    /// against it).
    func load(_ url: URL) async throws -> (Data, URL)
}

struct URLSessionHLSLoader: HLSLoading {
    var session: URLSession = .shared

    func load(_ url: URL) async throws -> (Data, URL) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(JRSClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RecordingError.badStatus(http.statusCode)
        }
        return (data, response.url ?? url)
    }
}

/// Records one live HLS stream to disk while it plays — or while it does not.
///
/// The loop re-reads the live playlist every half target duration, fetches
/// segments it has not seen, decrypts AES-128 ones and appends them to the
/// recording's log. Missed segments, a reconnect or a channel switch become a
/// discontinuity, so playback jumps the gap instead of stalling on it. A
/// stream that keeps failing is re-resolved from its channel page (signed
/// stream URLs expire), then from the match's other channels.
@MainActor
final class HLSRecorder: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case recording
        case reconnecting
        case finished
    }

    nonisolated let id: String
    @Published private(set) var info: RecordingInfo
    @Published private(set) var phase: Phase = .recording
    @Published private(set) var sourceIndex: Int
    let sources: [MatchSource]

    var onFinish: ((HLSRecorder) -> Void)?

    static let minimumFreeBytes: Int64 = 500 * 1_024 * 1_024
    static let maximumDuration: Double = 5 * 3_600
    /// Consecutive failed playlist reads before the stream is re-resolved.
    static let failuresBeforeResolve = 5
    /// Re-resolve rounds (about 15 s each) before giving up, ≈ 10 minutes.
    static let resolveRoundsBeforeGivingUp = 40

    private let folder: RecordingFolder
    private let loader: HLSLoading
    private let resolve: (URL) async throws -> URL
    private let sleep: (Double) async -> Void
    private let freeSpace: () -> Int64?
    private var streamURL: URL?
    private var pendingSource: Int?
    private var task: Task<Void, Never>?

    init(
        info: RecordingInfo,
        folder: RecordingFolder,
        streamURL: URL?,
        sources: [MatchSource],
        sourceIndex: Int,
        loader: HLSLoading = URLSessionHLSLoader(),
        resolve: @escaping (URL) async throws -> URL = { try await StreamResolver().resolve(sourcePageURL: $0) },
        sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        freeSpace: @escaping () -> Int64? = { RecordingStore.standard.availableCapacity() }
    ) {
        self.id = info.id
        self.info = info
        self.folder = folder
        self.streamURL = streamURL
        self.sources = sources
        self.sourceIndex = sourceIndex
        self.loader = loader
        self.resolve = resolve
        self.sleep = sleep
        self.freeSpace = freeSpace
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    /// Ends the recording now; what is on disk stays playable.
    func stop(reason: String = "已手动停止") {
        task?.cancel()
        finish(reason)
    }

    /// Write the latest counters now, e.g. before the app is suspended.
    func flushInfo() {
        try? folder.writeInfo(info)
    }

    /// Record a different channel from the next playlist read on.
    func switchSource(to index: Int) {
        guard sources.indices.contains(index), phase != .finished else { return }
        pendingSource = index
    }

    /// Runs the loop to completion. Exposed for tests; the app calls `start()`.
    func run() async {
        var lastSequence: Int?
        var recentPaths: [String] = []
        var discontinuity = false
        var failures = 0
        var resolveRounds = 0
        var currentMap: URL?
        var keys: [URL: Data] = [:]

        while !Task.isCancelled, phase != .finished {
            if let index = pendingSource {
                pendingSource = nil
                sourceIndex = index
                info.channelName = sources[index].name
                streamURL = nil
                lastSequence = nil
                discontinuity = true
            }
            if info.duration >= Self.maximumDuration {
                return finish("已录满 5 小时，自动停止")
            }
            if let free = freeSpace(), free < Self.minimumFreeBytes {
                return finish("存储空间不足，已自动停止")
            }

            do {
                let mediaURL: URL
                if let streamURL { mediaURL = streamURL } else {
                    phase = .reconnecting
                    mediaURL = try await resolveStream()
                    streamURL = mediaURL
                }
                let (data, finalURL) = try await loader.load(mediaURL)
                guard !Task.isCancelled, phase != .finished else { return }
                let playlist = HLSPlaylist.parse(String(decoding: data, as: UTF8.self), baseURL: finalURL)

                if playlist.isMaster {
                    if playlist.hasSeparateAudio { throw RecordingError.separateAudio }
                    streamURL = playlist.bestVariant?.url
                    continue
                }
                guard !playlist.segments.isEmpty || playlist.isEnded else { throw RecordingError.emptyPlaylist }
                failures = 0
                resolveRounds = 0
                phase = .recording

                // A live window that jumps backwards is a restarted stream.
                let newest = playlist.segments.last?.sequence ?? 0
                let restarted = lastSequence.map { newest < $0 - 3 } ?? false
                let fresh = playlist.segments.filter { segment in
                    !recentPaths.contains(segment.url.path)
                        && (restarted || lastSequence.map { segment.sequence > $0 } ?? true)
                }
                if restarted { discontinuity = true }
                if let last = lastSequence, let first = fresh.first, !restarted, first.sequence > last + 1 {
                    discontinuity = true
                    info.gapCount += 1
                }

                var index = 0
                while index < fresh.count {
                    let batch = Array(fresh[index..<min(index + 2, fresh.count)])
                    index += batch.count
                    let results = await download(batch)
                    guard !Task.isCancelled, phase != .finished else { return }
                    for (segment, result) in zip(batch, results) {
                        lastSequence = segment.sequence
                        recentPaths.append(segment.url.path)
                        if recentPaths.count > 64 { recentPaths.removeFirst(recentPaths.count - 64) }
                        switch result {
                        case .success(let bytes):
                            try await store(segment, bytes: bytes, discontinuity: discontinuity,
                                            currentMap: &currentMap, keys: &keys)
                            discontinuity = false
                        case .failure:
                            if !discontinuity { info.gapCount += 1 }
                            discontinuity = true
                        }
                    }
                }

                if playlist.isEnded { return finish("直播已结束") }
                await sleep(max(1, playlist.targetDuration / 2))
            } catch let error as RecordingError where error.isFatal {
                return finish(error.localizedDescription)
            } catch {
                guard !Task.isCancelled, phase != .finished else { return }
                failures += 1
                phase = .reconnecting
                if failures >= Self.failuresBeforeResolve {
                    failures = 0
                    resolveRounds += 1
                    if resolveRounds > Self.resolveRoundsBeforeGivingUp {
                        return finish("直播源长时间无法连接，录像已结束")
                    }
                    streamURL = nil
                    lastSequence = nil
                    if !discontinuity { info.gapCount += 1 }
                    discontinuity = true
                }
                await sleep(3)
            }
        }
    }

    // MARK: - Steps

    /// The recorded channel first, then the others in list order.
    private func resolveStream() async throws -> URL {
        let order = [sourceIndex] + sources.indices.filter { $0 != sourceIndex }
        var lastError: Error = RecordingError.emptyPlaylist
        for index in order {
            do {
                let url = try await resolve(sources[index].pageURL)
                if index != sourceIndex {
                    sourceIndex = index
                    info.channelName = sources[index].name
                }
                return url
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func download(_ segments: [HLSPlaylist.Segment]) async -> [Result<Data, Error>] {
        let loader = loader
        return await withTaskGroup(of: (Int, Result<Data, Error>).self) { group in
            for (offset, segment) in segments.enumerated() {
                group.addTask {
                    do { return (offset, .success(try await loader.load(segment.url).0)) } catch { return (offset, .failure(error)) }
                }
            }
            var results = [Result<Data, Error>](repeating: .failure(RecordingError.emptyPlaylist), count: segments.count)
            for await (offset, result) in group { results[offset] = result }
            return results
        }
    }

    private func store(
        _ segment: HLSPlaylist.Segment,
        bytes: Data,
        discontinuity: Bool,
        currentMap: inout URL?,
        keys: inout [URL: Data]
    ) async throws {
        var payload = bytes
        if let key = segment.key {
            switch key.method {
            case .none: break
            case .unsupported(let method): throw RecordingError.unsupportedEncryption(method)
            case .aes128:
                guard let keyURL = key.url else { throw RecordingError.decryptionFailed }
                let keyData: Data
                if let cached = keys[keyURL] { keyData = cached } else {
                    keyData = try await loader.load(keyURL).0
                    keys[keyURL] = keyData
                }
                let iv = key.iv ?? Self.sequenceIV(segment.sequence)
                guard let plain = Self.decryptAES128(payload, key: keyData, iv: iv) else {
                    throw RecordingError.decryptionFailed
                }
                payload = plain
            }
        }

        let number = info.segmentCount + 1
        if let mapURL = segment.mapURL, mapURL != currentMap {
            let mapData = try await loader.load(mapURL).0
            let name = String(format: "init-%06d.mp4", number)
            try folder.writeFile(name, data: mapData)
            try folder.append(.map(file: name))
            currentMap = mapURL
            info.bytes += Int64(mapData.count)
        }

        let name = String(format: "%06d.%@", number, Self.fileExtension(for: segment.url))
        try folder.writeFile(name, data: payload)
        try folder.append(.segment(file: name, duration: segment.duration, discontinuity: discontinuity))
        info.segmentCount = number
        info.duration += segment.duration
        info.bytes += Int64(payload.count)
        if number % 5 == 1 { try? folder.writeInfo(info) }
    }

    private func finish(_ reason: String) {
        guard phase != .finished else { return }
        phase = .finished
        info.endedAt = Date()
        info.endReason = reason
        try? folder.writeInfo(info)
        onFinish?(self)
    }

    // MARK: - Helpers

    static func fileExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["ts", "m4s", "mp4", "m4v", "aac", "m4a"].contains(ext) ? ext : "ts"
    }

    /// AES-128 HLS without an IV attribute uses the media sequence number,
    /// big-endian, as the IV.
    static func sequenceIV(_ sequence: Int) -> Data {
        var data = Data(repeating: 0, count: 8)
        withUnsafeBytes(of: UInt64(sequence).bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    static func decryptAES128(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, data.count, out.baseAddress, outputCapacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written)
    }
}
