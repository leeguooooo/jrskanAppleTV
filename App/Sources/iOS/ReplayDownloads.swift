import Foundation
import SwiftUI
import UIKit

/// One downloaded (or downloading) recording.
struct ReplayDownload: Codable, Identifiable, Equatable {
    enum Phase: String, Codable { case queued, downloading, paused, failed, finished }

    /// The Weibo video id.
    let id: String
    let video: ReplayVideo
    /// The fixture for 数据, kept so an offline replay needs no ESPN look-up.
    let fixture: LiveMatch?
    /// Which rendition ("mp4_720p"); renewed links must be the same file.
    let label: String
    var expectedBytes: Int64?
    var urlPath: String?
    var totalBytes: Int64?
    var receivedBytes: Int64 = 0
    var phase: Phase = .queued
    var message: String?
    var createdAt = Date()
}

/// Downloads replays into Application Support (not Documents, so they never
/// show in the Files app; excluded from backup) for offline viewing.
///
/// A recording is fetched in 64 MB byte ranges on a background URLSession.
/// Weibo's links expire after about an hour, so each range asks for a link
/// that still has a quarter of an hour left, renewing it when needed; a
/// renewed link must point at the same file (same path, same total size) or
/// the download starts over. Only a 206 whose range starts exactly at the
/// file's current length is appended, and that length is the resume point,
/// so a crash between appending and saving can never duplicate bytes.
@MainActor
final class ReplayDownloadCenter: NSObject, ObservableObject {
    static let shared = ReplayDownloadCenter()
    static let chunkSize: Int64 = 64 << 20
    static let sessionID = "com.leeguoo.jrskan.replay-downloads"

    @Published private(set) var items: [ReplayDownload] = []
    /// AVKit-free progress for rows: bytes on disk plus the running chunk.
    @Published private(set) var liveBytes: [String: Int64] = [:]
    /// Handed over by the app delegate when the system wakes us for this session.
    var backgroundCompletion: (() -> Void)?

    private var failures: [String: Int] = [:]
    private var debugBroke = false
    private var starting = Set<String>()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // No browser User-Agent: Weibo's CDN answers a "Mozilla" agent without a
        // weibo.com Referer with 403 (hotlink protection). CFNetwork's own is fine.
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    nonisolated static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplayDownloads", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(values)
        }
        return url
    }

    nonisolated static func fileURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).mp4") }
    private static var indexURL: URL { directory.appendingPathComponent("index.json") }

    nonisolated static func fileSize(_ id: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: fileURL(id).path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    override private init() {
        super.init()
        if let data = try? Data(contentsOf: Self.indexURL),
           let saved = try? JSONDecoder().decode([ReplayDownload].self, from: data) {
            items = saved.map { item in
                var item = item
                item.receivedBytes = Self.fileSize(item.id)
                return item
            }
        }
        ReplayLocalFiles.lookup = { id in ReplayDownloadCenter.shared.localFile(for: id) }
        reconcile()
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ReplayDownloadCenter.shared.reviveStalledTasks() }
        }
    }

    // MARK: Queries

    func item(_ id: String) -> ReplayDownload? { items.first { $0.id == id } }

    func localFile(for id: String) -> URL? {
        guard let item = item(id), item.phase == .finished else { return nil }
        let url = Self.fileURL(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var usedBytes: Int64 { items.reduce(0) { $0 + Self.fileSize($1.id) } }

    func progress(_ id: String) -> Double? {
        guard let item = item(id), let total = item.totalBytes ?? item.expectedBytes, total > 0 else { return nil }
        return min(1, Double(liveBytes[id] ?? item.receivedBytes) / Double(total))
    }

    // MARK: Actions

    func download(_ video: ReplayVideo, stream: ReplayStream, fixture: LiveMatch?) {
        if let existing = item(video.id), existing.phase != .failed { return }
        items.removeAll { $0.id == video.id }
        try? FileManager.default.removeItem(at: Self.fileURL(video.id))
        let item = ReplayDownload(id: video.id, video: video, fixture: fixture, label: stream.label,
                                  expectedBytes: stream.size, urlPath: stream.url.path)
        if let size = stream.size, !hasRoom(for: size) {
            var failed = item
            failed.phase = .failed
            failed.message = "手机存储空间不够（还需要约 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))）"
            items.insert(failed, at: 0)
            save()
            return
        }
        items.insert(item, at: 0)
        save()
        pump()
    }

    func pause(_ id: String) {
        update(id) { $0.phase = .paused; $0.message = nil }
        cancelTasks(for: id)
        pump()
    }

    func resume(_ id: String) {
        failures[id] = 0
        update(id) { $0.phase = .queued; $0.message = nil }
        pump()
    }

    func delete(_ id: String) {
        cancelTasks(for: id)
        items.removeAll { $0.id == id }
        liveBytes[id] = nil
        try? FileManager.default.removeItem(at: Self.fileURL(id))
        save()
        pump()
    }

    // MARK: Engine

    /// One recording at a time, oldest first.
    private func pump() {
        guard !items.contains(where: { $0.phase == .downloading }) else { return }
        guard let next = items.last(where: { $0.phase == .queued }) else { return }
        startChunk(next.id)
    }

    private func startChunk(_ id: String, freshLink: Bool = false) {
        guard !starting.contains(id), let item = item(id), item.phase == .queued || item.phase == .downloading else { return }
        starting.insert(id)
        update(id) { $0.phase = .downloading }
        Task {
            defer { starting.remove(id) }
            do {
                let stream = try await link(for: item, fresh: freshLink)
                guard let current = self.item(id), current.phase == .downloading else { return }
                // The same file or nothing: a different path or size starts over.
                if let pinned = current.urlPath, pinned != stream.url.path {
                    restart(id, reason: "微博换了视频文件，重新下载")
                    return
                }
                let offset = Self.fileSize(id)
                if let total = current.totalBytes, offset >= total { finish(id); return }
                var end = offset + Self.chunkSize - 1
                if let total = current.totalBytes { end = min(end, total - 1) }
                var url = stream.url
                #if DEBUG
                // `-download-break`: the first range after launch uses a broken
                // signature (403, like an expired link) to exercise renewal.
                if CommandLine.arguments.contains("-download-break"), !debugBroke,
                   var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    debugBroke = true
                    components.queryItems = components.queryItems?.map { $0.name == "ssig" ? URLQueryItem(name: "ssig", value: "broken0000") : $0 }
                    url = components.url ?? url
                    print("download: debug break at \(offset)")
                }
                #endif
                var request = URLRequest(url: url)
                request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                let task = session.downloadTask(with: request)
                task.taskDescription = "\(id)|\(offset)"
                task.resume()
            } catch {
                chunkFailed(id, status: nil, message: "拿不到下载地址：\(error.localizedDescription)")
            }
        }
    }

    /// A link with at least 15 minutes left, for the same rendition.
    private func link(for item: ReplayDownload, fresh: Bool) async throws -> ReplayStream {
        if !fresh, let cached = ReplayCache.read("streams:\(item.id)", as: [ReplayStream].self)?.value,
           let match = cached.first(where: { $0.label == item.label }),
           let expires = match.expires, expires.timeIntervalSinceNow > 15 * 60 {
            return match
        }
        let streams = ReplayParsing.streams(try await WeiboClient.shared.status(item.id))
        ReplayCache.storeStreams(streams, for: item.id)
        guard let match = streams.first(where: { $0.label == item.label }) else {
            throw URLError(.fileDoesNotExist)
        }
        return match
    }

    fileprivate enum ChunkResult {
        case appended(total: Int64)
        case rejected(status: Int, message: String)
    }

    fileprivate func chunkDone(_ id: String, _ result: ChunkResult) {
        guard item(id) != nil else { return }
        switch result {
        case .appended(let total):
            failures[id] = 0
            let size = Self.fileSize(id)
            if let known = item(id)?.totalBytes, known != total {
                restart(id, reason: "视频文件大小变了，重新下载")
                return
            }
            update(id) { $0.totalBytes = total; $0.receivedBytes = size }
            liveBytes[id] = nil
            #if DEBUG
            print("download: \(id) \(size)/\(total)")
            #endif
            if size >= total { finish(id) } else if item(id)?.phase == .downloading { startChunk(id) }
        case .rejected(let status, let message):
            chunkFailed(id, status: status, message: message)
        }
    }

    private func chunkFailed(_ id: String, status: Int?, message: String) {
        guard let item = item(id), item.phase == .downloading else { return }
        #if DEBUG
        print("download: chunk failed \(status ?? 0), renewing=\(status == 403 || status == 410 || status == nil)")
        #endif
        let count = (failures[id] ?? 0) + 1
        failures[id] = count
        if status == 404 || count > 5 {
            update(id) { $0.phase = .failed; $0.message = status == 404 ? "这个视频已被删除" : message }
            pump()
            return
        }
        // 403 is an expired link: renew it. Anything else: try again shortly.
        let renew = status == 403 || status == 410 || status == nil
        Task {
            try? await Task.sleep(nanoseconds: UInt64(min(30, count * count)) * 1_000_000_000)
            startChunk(id, freshLink: renew)
        }
    }

    private func finish(_ id: String) {
        update(id) { $0.phase = .finished; $0.message = nil; $0.receivedBytes = Self.fileSize(id) }
        #if DEBUG
        print("download: finished \(id) \(Self.fileSize(id))")
        #endif
        liveBytes[id] = nil
        pump()
    }

    private func restart(_ id: String, reason: String) {
        try? FileManager.default.removeItem(at: Self.fileURL(id))
        update(id) { $0.urlPath = nil; $0.totalBytes = nil; $0.receivedBytes = 0; $0.message = reason }
        startChunk(id, freshLink: true)
    }

    private func update(_ id: String, _ change: (inout ReplayDownload) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }

    private func cancelTasks(for id: String) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription?.hasPrefix("\(id)|") == true { task.cancel() }
        }
    }

    private func hasRoom(for bytes: Int64) -> Bool {
        let values = try? Self.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return free > bytes + 500 << 20
    }

    /// After a relaunch: anything marked downloading with no task gets one.
    private func reconcile() {
        session.getAllTasks { tasks in
            let running = Set(tasks.compactMap { $0.taskDescription?.split(separator: "|").first.map(String.init) })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let center = ReplayDownloadCenter.shared
                    for item in center.items where item.phase == .downloading && !running.contains(item.id) {
                        center.startChunk(item.id)
                    }
                    center.pump()
                }
            }
        }
    }

    /// Chunks queued while in the background run when the system likes; back
    /// in the foreground, restart any that have not moved.
    private func reviveStalledTasks() {
        session.getAllTasks { tasks in
            let stalled = tasks.filter { $0.state == .running && $0.countOfBytesReceived == 0 }
            stalled.forEach { $0.cancel() }
            let ids = stalled.compactMap { $0.taskDescription?.split(separator: "|").first.map(String.init) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for id in ids { ReplayDownloadCenter.shared.startChunk(id) }
                }
            }
        }
    }
}

extension ReplayDownloadCenter: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let parts = downloadTask.taskDescription?.split(separator: "|"), parts.count == 2,
              let offset = Int64(parts[1]) else { return }
        let id = String(parts[0])
        DispatchQueue.main.async {
            MainActor.assumeIsolated { ReplayDownloadCenter.shared.liveBytes[id] = offset + totalBytesWritten }
        }
    }

    /// The temporary file is gone when this returns: check and append here.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let parts = downloadTask.taskDescription?.split(separator: "|"), parts.count == 2,
              let offset = Int64(parts[1]) else { return }
        let id = String(parts[0])
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        let result: ChunkResult
        if status == 206, let range = response?.value(forHTTPHeaderField: "Content-Range"),
           let parsed = Self.parseContentRange(range), parsed.start == offset,
           Self.fileSize(id) == offset {
            result = Self.append(location, to: Self.fileURL(id)) ? .appended(total: parsed.total)
                : .rejected(status: -1, message: "写入文件失败")
        } else {
            result = .rejected(status: status, message: "下载出错（\(status)）")
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { ReplayDownloadCenter.shared.chunkDone(id, result) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as? URLError)?.code != .cancelled,
              let id = task.taskDescription?.split(separator: "|").first.map(String.init) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                ReplayDownloadCenter.shared.chunkFailed(id, status: status, message: "网络中断：\(error.localizedDescription)")
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                ReplayDownloadCenter.shared.backgroundCompletion?()
                ReplayDownloadCenter.shared.backgroundCompletion = nil
            }
        }
    }

    /// "bytes 0-67108863/1062163937" → (0, 1062163937)
    nonisolated static func parseContentRange(_ header: String) -> (start: Int64, total: Int64)? {
        let pattern = #"bytes\s+(\d+)-(\d+)/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let start = Range(match.range(at: 1), in: header).flatMap({ Int64(header[$0]) }),
              let total = Range(match.range(at: 3), in: header).flatMap({ Int64(header[$0]) }) else { return nil }
        return (start, total)
    }

    nonisolated private static func append(_ source: URL, to destination: URL) -> Bool {
        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        guard let output = try? FileHandle(forWritingTo: destination),
              let input = try? FileHandle(forReadingFrom: source) else { return false }
        defer { try? output.close(); try? input.close() }
        do {
            try output.seekToEnd()
            while let data = try input.read(upToCount: 4 << 20), !data.isEmpty { try output.write(contentsOf: data) }
            try output.synchronize()
            return true
        } catch {
            return false
        }
    }
}
