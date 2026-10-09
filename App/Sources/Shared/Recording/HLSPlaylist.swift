import Foundation

/// The parts of an HLS playlist a recorder needs. A master playlist only
/// fills `variants` (and `hasSeparateAudio`); a media playlist fills the rest.
///
/// The live sources seen so far are a one-variant master pointing at a plain
/// MPEG-TS media playlist with 2-second segments and a three-segment window,
/// but AES-128 keys and fMP4 init segments (`EXT-X-MAP`) are handled too.
struct HLSPlaylist: Equatable {
    struct Variant: Equatable {
        let url: URL
        let bandwidth: Int
    }

    struct Key: Equatable {
        enum Method: Equatable { case none, aes128, unsupported(String) }
        let method: Method
        let url: URL?
        /// Explicit IV; when absent AES-128 uses the media sequence number.
        let iv: Data?
    }

    struct Segment: Equatable {
        let sequence: Int
        let url: URL
        let duration: Double
        let key: Key?
        let mapURL: URL?
        let discontinuity: Bool
    }

    var variants: [Variant] = []
    /// `EXT-X-MEDIA` audio with its own URI: the video variant has no sound
    /// of its own, and recording two playlists in step is out of scope.
    var hasSeparateAudio = false
    var targetDuration: Double = 0
    var mediaSequence = 0
    var segments: [Segment] = []
    var isEnded = false

    var isMaster: Bool { !variants.isEmpty }

    /// The variant worth recording: the one with the most bandwidth.
    var bestVariant: Variant? { variants.max { $0.bandwidth < $1.bandwidth } }

    static func parse(_ text: String, baseURL: URL) -> HLSPlaylist {
        var playlist = HLSPlaylist()
        var key: Key?
        var mapURL: URL?
        var pendingDuration: Double?
        var pendingBandwidth: Int?
        var pendingDiscontinuity = false
        var sequence: Int?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let (tag, value) = splitTag(line)
                switch tag {
                case "#EXT-X-STREAM-INF":
                    pendingBandwidth = Int(attributes(value)["BANDWIDTH"] ?? "") ?? 0
                case "#EXT-X-MEDIA":
                    let attrs = attributes(value)
                    if attrs["TYPE"] == "AUDIO", attrs["URI"] != nil { playlist.hasSeparateAudio = true }
                case "#EXT-X-TARGETDURATION":
                    playlist.targetDuration = Double(value) ?? 0
                case "#EXT-X-MEDIA-SEQUENCE":
                    playlist.mediaSequence = Int(value) ?? 0
                case "#EXTINF":
                    pendingDuration = Double(value.split(separator: ",", maxSplits: 1).first.map(String.init) ?? "") ?? 0
                case "#EXT-X-DISCONTINUITY":
                    pendingDiscontinuity = true
                case "#EXT-X-ENDLIST":
                    playlist.isEnded = true
                case "#EXT-X-KEY":
                    let attrs = attributes(value)
                    let method: Key.Method
                    switch attrs["METHOD"]?.uppercased() {
                    case "NONE", nil: method = .none
                    case "AES-128": method = .aes128
                    case let other?: method = .unsupported(other)
                    }
                    key = method == .none ? nil : Key(
                        method: method,
                        url: attrs["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL },
                        iv: attrs["IV"].flatMap(hexData)
                    )
                case "#EXT-X-MAP":
                    mapURL = attributes(value)["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
                default:
                    break
                }
                continue
            }

            guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
            if let bandwidth = pendingBandwidth {
                playlist.variants.append(Variant(url: url, bandwidth: bandwidth))
                pendingBandwidth = nil
            } else if let duration = pendingDuration {
                let number = sequence ?? playlist.mediaSequence
                playlist.segments.append(Segment(sequence: number, url: url, duration: duration,
                    key: key, mapURL: mapURL, discontinuity: pendingDiscontinuity))
                sequence = number + 1
                pendingDuration = nil
                pendingDiscontinuity = false
            }
        }
        return playlist
    }

    private static func splitTag(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        return (String(line[..<colon]), String(line[line.index(after: colon)...]))
    }

    /// `KEY=value,KEY="quoted, value"` → dictionary, quotes removed.
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var quoted = false
        func flush() {
            let name = key.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { result[name] = value }
            key = ""; value = ""; readingKey = true
        }
        for character in text {
            if readingKey {
                if character == "=" { readingKey = false } else if character != "," { key.append(character) }
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                flush()
            } else {
                value.append(character)
            }
        }
        if !key.isEmpty { flush() }
        return result
    }

    private static func hexData(_ text: String) -> Data? {
        var hex = text
        if hex.lowercased().hasPrefix("0x") { hex.removeFirst(2) }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// One line of a recording's segment log, in recording order.
enum RecordedEntry: Equatable {
    /// An fMP4 init segment that applies to the segments after it.
    case map(file: String)
    case segment(file: String, duration: Double, discontinuity: Bool)
}

/// The playlist a finished (or still growing) recording is played from.
/// Segments are stored decrypted, so it never carries keys.
enum RecordingPlaylist {
    static func render(_ entries: [RecordedEntry], ended: Bool) -> String {
        let longest = entries.reduce(0.0) { result, entry in
            if case .segment(_, let duration, _) = entry { return max(result, duration) }
            return result
        }
        let usesMap = entries.contains { if case .map = $0 { return true } else { return false } }
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:\(usesMap ? 6 : 3)",
            "#EXT-X-TARGETDURATION:\(max(1, Int(longest.rounded(.up))))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:\(ended ? "VOD" : "EVENT")"
        ]
        var first = true
        for entry in entries {
            switch entry {
            case .map(let file):
                lines.append("#EXT-X-MAP:URI=\"\(file)\"")
            case .segment(let file, let duration, let discontinuity):
                if discontinuity && !first { lines.append("#EXT-X-DISCONTINUITY") }
                lines.append("#EXTINF:\(String(format: "%.3f", duration)),")
                lines.append(file)
                first = false
            }
        }
        if ended { lines.append("#EXT-X-ENDLIST") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The on-disk log: one tab-separated line per entry, appended as
    /// segments arrive so a crash loses at most the line being written.
    static func logLine(_ entry: RecordedEntry) -> String {
        switch entry {
        case .map(let file): return "M\t\(file)\n"
        case .segment(let file, let duration, let discontinuity):
            return "S\t\(file)\t\(String(format: "%.3f", duration))\t\(discontinuity ? 1 : 0)\n"
        }
    }

    static func parseLog(_ text: String) -> [RecordedEntry] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "M" where fields.count >= 2: return .map(file: fields[1])
            case "S" where fields.count >= 4:
                guard let duration = Double(fields[2]) else { return nil }
                return .segment(file: fields[1], duration: duration, discontinuity: fields[3] == "1")
            default: return nil
            }
        }
    }
}
