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
    /// The shareable MP4 in Documents/录像 once it has been made; the
    /// segments are deleted then.
    var videoFile: String?

    var isFinished: Bool { endedAt != nil }

    /// "10月9日 湖人 vs 勇士", safe as a file name.
    var suggestedFileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HHmm"
        let raw = "\(formatter.string(from: startedAt)) \(title)"
        return raw.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
    }
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

    /// The segments in order, for the MP4 export.
    func segments() -> [TSRemuxer.Segment] {
        entries().compactMap { entry in
            if case .segment(let file, _, let gap) = entry {
                return TSRemuxer.Segment(url: url.appendingPathComponent(file), discontinuity: gap)
            }
            return nil
        }
    }

    var hasSegments: Bool { FileManager.default.fileExists(atPath: logURL.path) }

    /// Everything but info.json, once the MP4 exists.
    func removeMedia() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for name in names where name != "info.json" {
            try? FileManager.default.removeItem(at: url.appendingPathComponent(name))
        }
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

    /// Finished MP4s, in Documents so the Files app shows them
    /// (On My iPhone › JRKAN › 录像) and they can be shared like any video.
    let videos: URL

    init(root: URL, videos: URL? = nil) {
        self.root = root
        self.videos = videos ?? root.appendingPathComponent("Videos", isDirectory: true)
    }

    static var standard: RecordingStore {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return RecordingStore(root: base.appendingPathComponent("Recordings", isDirectory: true),
                              videos: documents.appendingPathComponent("录像", isDirectory: true))
    }

    func videoURL(_ info: RecordingInfo) -> URL? {
        guard let name = info.videoFile else { return nil }
        let url = videos.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A free name for a new MP4: "<name>.mp4", then "<name> 2.mp4", …
    func newVideoURL(named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        var candidate = videos.appendingPathComponent("\(name).mp4")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = videos.appendingPathComponent("\(name) \(number).mp4")
            number += 1
        }
        return candidate
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
        if let info = folder(id).readInfo(), let video = videoURL(info) {
            try? FileManager.default.removeItem(at: video)
        }
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
