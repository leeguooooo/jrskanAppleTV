import Combine
import Foundation

/// Watermark and ad slots, edited in Cloudflare (KV key `jrkan` behind
/// config.leeguoo.com, see worker/). Every field decodes with a default, so
/// a config written for a newer app, or a half-filled one, still works.
struct AppConfig: Codable, Equatable {
    struct Watermark: Codable, Equatable {
        enum Motion: String, Codable { case hop, drift, fixed }

        var enabled = true
        /// Shown in turn, one per hop.
        var texts = ["leeguoo.com"]
        var motion = Motion.drift
        /// Seconds between hops, or the length of one drift leg.
        var interval: Double = 8
        var opacity: Double = 0.55
        var hideForMembers = false

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let base = Watermark()
            enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? base.enabled
            let texts = ((try? c.decode([String].self, forKey: .texts)) ?? []).filter { !$0.isEmpty }
            self.texts = texts.isEmpty ? base.texts : texts
            motion = (try? c.decode(Motion.self, forKey: .motion)) ?? base.motion
            interval = min(600, max(5, (try? c.decode(Double.self, forKey: .interval)) ?? base.interval))
            opacity = min(1, max(0.1, (try? c.decode(Double.self, forKey: .opacity)) ?? base.opacity))
            hideForMembers = (try? c.decode(Bool.self, forKey: .hideForMembers)) ?? base.hideForMembers
        }
    }

    struct Slot: Codable, Equatable {
        var enabled = false
        var title = ""
        var detail = ""
        var url = ""
        var hideForMembers = true

        init(enabled: Bool = false, title: String = "", detail: String = "", url: String = "", hideForMembers: Bool = true) {
            self.enabled = enabled
            self.title = title
            self.detail = detail
            self.url = url
            self.hideForMembers = hideForMembers
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            detail = (try? c.decode(String.self, forKey: .detail)) ?? ""
            url = (try? c.decode(String.self, forKey: .url)) ?? ""
            hideForMembers = (try? c.decode(Bool.self, forKey: .hideForMembers)) ?? true
        }

        var link: URL? {
            guard let url = URL(string: url), url.scheme == "https" else { return nil }
            return url
        }
    }

    /// Match recordings from Weibo (回看). Defaults work with no remote
    /// config at all; the remote copy exists to switch it off or retune it
    /// when Weibo changes.
    struct Replay: Codable, Equatable {
        var enabled = true
        /// Weibo uids whose video feeds make up the 回看 list.
        var uploaders = ["7551290258", "2358578625"]
        /// Appended to "主队vs客队" for a match's own search.
        var searchSuffix = " 回放"
        /// Shorter videos are highlights, not recordings.
        var minDuration: Double = 600
        /// Untitled videos at least this long count as the whole game.
        var fullDuration: Double = 5400
        /// How long after kickoff an undated upload still belongs to the match.
        var windowHours: Double = 48

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let base = Replay()
            enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? base.enabled
            let uploaders = ((try? c.decode([String].self, forKey: .uploaders)) ?? [])
                .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            self.uploaders = uploaders.isEmpty ? base.uploaders : Array(uploaders.prefix(10))
            searchSuffix = (try? c.decode(String.self, forKey: .searchSuffix)) ?? base.searchSuffix
            minDuration = min(3600, max(60, (try? c.decode(Double.self, forKey: .minDuration)) ?? base.minDuration))
            fullDuration = min(14_400, max(1800, (try? c.decode(Double.self, forKey: .fullDuration)) ?? base.fullDuration))
            windowHours = min(240, max(6, (try? c.decode(Double.self, forKey: .windowHours)) ?? base.windowHours))
        }

        var rules: ReplayRules {
            ReplayRules(minDuration: minDuration, fullDuration: fullDuration, windowHours: windowHours)
        }
    }

    var watermark = Watermark()
    var slots: [String: Slot] = [:]
    var replay = Replay()

    init(watermark: Watermark = Watermark(), slots: [String: Slot] = [:], replay: Replay = Replay()) {
        self.watermark = watermark
        self.slots = slots
        self.replay = replay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        watermark = (try? c.decode(Watermark.self, forKey: .watermark)) ?? Watermark()
        slots = (try? c.decode([String: Slot].self, forKey: .slots)) ?? [:]
        replay = (try? c.decode(Replay.self, forKey: .replay)) ?? Replay()
    }

    /// The watermark to draw, or nil when it is off for this viewer.
    func visibleWatermark(isMember: Bool) -> Watermark? {
        guard watermark.enabled, !(watermark.hideForMembers && isMember) else { return nil }
        return watermark
    }

    /// A slot worth showing: enabled, has a title, not hidden for members.
    func slot(_ id: String, isMember: Bool) -> Slot? {
        guard let slot = slots[id], slot.enabled, !slot.title.isEmpty,
              !(slot.hideForMembers && isMember) else { return nil }
        return slot
    }
}

/// Holds the latest config: the cached copy at launch, the fetched one after.
/// A failed fetch keeps whatever was there; with nothing cached the built-in
/// defaults (today's "leeguoo.com" watermark, no banner) apply.
@MainActor
final class AppConfigStore: ObservableObject {
    static let shared = AppConfigStore()
    static let endpoint = URL(string: "https://config.leeguoo.com/v1/jrkan.json")!
    static let refreshInterval: TimeInterval = 10 * 60

    @Published private(set) var config: AppConfig
    /// Set by the app from the account session; slots can hide for members.
    @Published var isMember = false

    private let defaults: UserDefaults
    private let session: URLSession
    private var lastFetch: Date?
    private static let cacheKey = "remoteConfig.jrkan"

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        if let data = defaults.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = cached
        } else {
            config = AppConfig()
        }
        #if DEBUG
        // `-config-json '<json>'` pins a config for screenshots, skipping the network.
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "-config-json"), index + 1 < args.count,
           let pinned = try? JSONDecoder().decode(AppConfig.self, from: Data(args[index + 1].utf8)) {
            config = pinned
            lastFetch = .distantFuture
        }
        #endif
    }

    var watermark: AnyPublisher<AppConfig.Watermark?, Never> {
        Publishers.CombineLatest($config, $isMember)
            .map { $0.visibleWatermark(isMember: $1) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func slot(_ id: String) -> AppConfig.Slot? {
        config.slot(id, isMember: isMember)
    }

    /// Launch and return to the foreground; at most every ten minutes.
    func refreshIfStale(now: Date = Date()) async {
        if let lastFetch, now.timeIntervalSince(lastFetch) < Self.refreshInterval { return }
        lastFetch = now
        await refresh()
    }

    func refresh() async {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let fetched = try? JSONDecoder().decode(AppConfig.self, from: data) else { return }
        defaults.set(data, forKey: Self.cacheKey)
        if fetched != config { config = fetched }
    }
}
