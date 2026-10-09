import Foundation

/// What the recordings list shows about one recording. Written to
/// `info.json` next to the segments when the recording starts, every few
/// segments while it runs, and when it ends.
struct RecordingInfo: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let matchID: String
    let title: String
    let league: String
    var channelName: String
    let startedAt: Date
    var endedAt: Date?
    var duration: Double = 0
    var bytes: Int64 = 0
    var segmentCount = 0
    /// Stretches the recorder could not fetch (missed segments, a channel
    /// switch, a reconnect); playback jumps over them.
    var gapCount = 0
    var endReason: String?

    var isFinished: Bool { endedAt != nil }
}

/// One recording's folder: `info.json`, the append-only `segments.log` and
/// the media files it names.
struct RecordingFolder: Sendable {
    let url: URL

    var infoURL: URL { url.appendingPathComponent("info.json") }
    var logURL: URL { url.appendingPathComponent("segments.log") }

    func readInfo() -> RecordingInfo? {
        guard let data = try? Data(contentsOf: infoURL) else { return nil }
        return try? RecordingStore.decoder.decode(RecordingInfo.self, from: data)
    }

    func writeInfo(_ info: RecordingInfo) throws {
        try RecordingStore.encoder.encode(info).write(to: infoURL, options: .atomic)
    }

    func writeFile(_ name: String, data: Data) throws {
        try data.write(to: url.appendingPathComponent(name))
    }

    func append(_ entry: RecordedEntry) throws {
        let line = Data(RecordingPlaylist.logLine(entry).utf8)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try line.write(to: logURL)
            return
        }
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    func entries() -> [RecordedEntry] {
        guard let data = try? Data(contentsOf: logURL) else { return [] }
        return RecordingPlaylist.parseLog(String(decoding: data, as: UTF8.self))
    }

    func playlist(ended: Bool) -> String {
        RecordingPlaylist.render(entries(), ended: ended)
    }
}

/// Recordings live in Application Support, outside iCloud backup: a match is
/// a couple of gigabytes, and they are this device's copies only.
struct RecordingStore: Sendable {
    let root: URL

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static var standard: RecordingStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RecordingStore(root: base.appendingPathComponent("Recordings", isDirectory: true))
    }

    func folder(_ id: String) -> RecordingFolder {
        RecordingFolder(url: root.appendingPathComponent(id, isDirectory: true))
    }

    func create(_ info: RecordingInfo) throws -> RecordingFolder {
        try ensureRoot()
        let folder = folder(info.id)
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try folder.writeInfo(info)
        return folder
    }

    /// Newest first.
    func list() -> [RecordingInfo] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.compactMap { folder($0).readInfo() }.sorted { $0.startedAt > $1.startedAt }
    }

    func delete(_ id: String) throws {
        let url = folder(id).url
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Bytes the system would still give an important write, or nil when the
    /// volume does not say.
    func availableCapacity() -> Int64? {
        try? ensureRoot()
        #if os(tvOS)
        // tvOS has no "important usage" figure (and nothing records there).
        return (try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init)
        #else
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #endif
    }

    private func ensureRoot() throws {
        guard !FileManager.default.fileExists(atPath: root.path) else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
