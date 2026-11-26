import CryptoKit
import Foundation

/// Small on-disk cache for 回看 (Caches/replay): the list, a match's search,
/// signed play links and ESPN look-ups are not fetched again while still good.
/// The OS may purge Caches at any time; everything here can be fetched again.
///
/// Lifetimes follow how fast each thing changes:
/// - uploader feeds (the 回看 list): 10 minutes, then shown while refreshing;
/// - a match's search: 15 minutes while uploads still arrive (first 6 hours
///   after kickoff), 2 hours for two days, then a day; nothing found: 10 minutes;
/// - play links: until 10 minutes before Weibo's own Expires;
/// - ESPN fixture: found 30 days, not found 6 hours.
enum ReplayCache {
    static var directoryOverride: URL?

    private static var directory: URL {
        let url = directoryOverride
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("replay", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Entry<Value: Codable>: Codable {
        let savedAt: Date
        let value: Value
    }

    static func read<Value: Codable>(_ key: String, as type: Value.Type = Value.self) -> (value: Value, savedAt: Date)? {
        guard let data = try? Data(contentsOf: file(key)),
              let entry = try? JSONDecoder().decode(Entry<Value>.self, from: data) else { return nil }
        return (entry.value, entry.savedAt)
    }

    static func write<Value: Codable>(_ key: String, _ value: Value, now: Date = Date()) {
        guard let data = try? JSONEncoder().encode(Entry(savedAt: now, value: value)) else { return }
        try? data.write(to: file(key), options: .atomic)
    }

    static func remove(_ key: String) {
        try? FileManager.default.removeItem(at: file(key))
    }

    /// Drops anything not written for a month (launch, off the main thread).
    static func prune(now: Date = Date()) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        for url in files {
            let modified = (try? url.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > 30 * 86_400 { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func file(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    // MARK: Lifetimes

    static let libraryLifetime: TimeInterval = 10 * 60

    /// How long a match's search stays good. Uploads keep arriving for a few
    /// hours after a game, then almost never.
    static func searchLifetime(kickoff: Date, foundAny: Bool, now: Date = Date()) -> TimeInterval {
        guard foundAny else { return 10 * 60 }
        let since = now.timeIntervalSince(kickoff)
        if since < 6 * 3600 { return 15 * 60 }
        if since < 48 * 3600 { return 2 * 3600 }
        return 24 * 3600
    }

    static func searchKey(home: String, away: String, kickoff: Date) -> String {
        "search:\(ReplayVideo.Matchup(left: home, right: away).key)@\(Int(ReplayParsing.beijingDay(kickoff).timeIntervalSince1970))"
    }

    /// A play link worth using: at least ten minutes left before it expires.
    static func usableStreams(for id: String, now: Date = Date()) -> [ReplayStream]? {
        guard let cached = read("streams:\(id)", as: [ReplayStream].self),
              let expires = cached.value.first?.expires, expires.timeIntervalSince(now) > 10 * 60 else { return nil }
        return cached.value
    }

    static func storeStreams(_ streams: [ReplayStream], for id: String) {
        guard !streams.isEmpty else { return }
        write("streams:\(id)", streams)
    }
}

/// Downloaded recordings, played from disk instead of Weibo. Only iPhone,
/// iPad and Mac download; the TV keeps the default (nothing downloaded).
@MainActor
enum ReplayLocalFiles {
    static var lookup: (String) -> URL? = { _ in nil }
}

extension ReplayVideo.Part: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "full": self = .full
        case "firstHalf": self = .firstHalf
        case "secondHalf": self = .secondHalf
        default:
            if raw.hasPrefix("period:"), let n = Int(raw.dropFirst(7)) { self = .period(n) } else { self = .other }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .full: try container.encode("full")
        case .firstHalf: try container.encode("firstHalf")
        case .secondHalf: try container.encode("secondHalf")
        case .period(let n): try container.encode("period:\(n)")
        case .other: try container.encode("other")
        }
    }
}
