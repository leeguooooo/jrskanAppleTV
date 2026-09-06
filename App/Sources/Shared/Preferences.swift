import Foundation

/// Everything the app remembers between launches. All of it lives in
/// `UserDefaults` on the Apple TV itself — no account, nothing leaves the box.
@MainActor
final class Preferences: ObservableObject {
    struct LastChannel: Codable, Equatable {
        let name: String
        let index: Int
        let watchedAt: Date
    }

    struct RecentWatch: Codable, Identifiable {
        let match: LiveMatch
        let channelName: String
        let watchedAt: Date
        var id: String { match.id }
    }

    struct ChannelPerformance: Codable {
        var successes = 0
        var failures = 0
        var averageStartup: TimeInterval = 20
        var lastFailure: Date?
        var updatedAt = Date()
        var reliability: Double { Double(successes + 1) / Double(successes + failures + 2) }
    }

    @Published private(set) var recentWatches: [RecentWatch] {
        didSet { if let data = try? JSONEncoder().encode(recentWatches) { store.set(data, forKey: Keys.recentWatches) } }
    }
    @Published private(set) var channelPerformance: [String: ChannelPerformance] {
        didSet { if let data = try? JSONEncoder().encode(channelPerformance) { store.set(data, forKey: Keys.channelPerformance) } }
    }

    @Published var favoriteTeams: Set<String> {
        didSet { store.set(Array(favoriteTeams).sorted(), forKey: Keys.favoriteTeams) }
    }

    /// Re-fetch the schedule every few minutes while the list is on screen.
    @Published var autoRefresh: Bool {
        didSet { store.set(autoRefresh, forKey: Keys.autoRefresh) }
    }

    /// When a channel fails to resolve or never shows a picture, move on to
    /// the next one without making the viewer pick it by hand.
    @Published var autoNextChannel: Bool {
        didSet { store.set(autoNextChannel, forKey: Keys.autoNextChannel) }
    }

    @Published var lastFilter: SportFilter {
        didSet { store.set(lastFilter.rawValue, forKey: Keys.lastFilter) }
    }

    @Published private(set) var lastChannels: [String: LastChannel] {
        didSet {
            if let data = try? JSONEncoder().encode(lastChannels) {
                store.set(data, forKey: Keys.lastChannels)
            }
        }
    }

    private let store: UserDefaults

    private enum Keys {
        static let favoriteTeams = "favoriteTeams"
        static let autoRefresh = "autoRefresh"
        static let autoNextChannel = "autoNextChannel"
        static let lastFilter = "lastFilter"
        static let lastChannels = "lastChannels"
        static let recentWatches = "recentWatches"
        static let channelPerformance = "channelPerformance"
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        favoriteTeams = Set(store.stringArray(forKey: Keys.favoriteTeams) ?? [])
        autoRefresh = store.object(forKey: Keys.autoRefresh) as? Bool ?? true
        autoNextChannel = store.object(forKey: Keys.autoNextChannel) as? Bool ?? true
        lastFilter = store.string(forKey: Keys.lastFilter).flatMap(SportFilter.init(rawValue:)) ?? .all

        var remembered: [String: LastChannel] = [:]
        if let data = store.data(forKey: Keys.lastChannels),
           let decoded = try? JSONDecoder().decode([String: LastChannel].self, from: data) {
            // Match IDs are per fixture; anything older than a week is a game
            // that is long over and would only grow the dictionary forever.
            let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            remembered = decoded.filter { $0.value.watchedAt > cutoff }
        }
        lastChannels = remembered
        let recent = store.data(forKey: Keys.recentWatches).flatMap { try? JSONDecoder().decode([RecentWatch].self, from: $0) } ?? []
        recentWatches = Array(recent.filter { Date().timeIntervalSince($0.watchedAt) < 7 * 86400 }.prefix(10))
        let performance = store.data(forKey: Keys.channelPerformance).flatMap { try? JSONDecoder().decode([String: ChannelPerformance].self, from: $0) } ?? [:]
        channelPerformance = performance.filter { Date().timeIntervalSince($0.value.updatedAt) < 30 * 86400 }
    }

    // MARK: Favorites

    func isFavorite(_ team: String) -> Bool {
        favoriteTeams.contains(team)
    }

    func toggleFavorite(_ team: String) {
        if favoriteTeams.contains(team) {
            favoriteTeams.remove(team)
        } else {
            favoriteTeams.insert(team)
        }
    }

    func follows(_ match: LiveMatch) -> Bool {
        favoriteTeams.contains(match.homeTeam) || favoriteTeams.contains(match.awayTeam)
    }

    // MARK: Watch history

    func rememberChannel(matchID: String, name: String, index: Int) {
        lastChannels[matchID] = LastChannel(name: name, index: index, watchedAt: Date())
    }

    func lastChannel(for matchID: String) -> LastChannel? {
        lastChannels[matchID]
    }

    func recordPlaybackSuccess(match: LiveMatch, source: MatchSource, index: Int,
                               startup: TimeInterval, now: Date = Date()) {
        lastChannels[match.id] = LastChannel(name: source.name, index: index, watchedAt: now)
        var saved = match
        saved.providerState = nil // History never pretends old live data is current.
        recentWatches.removeAll { $0.id == match.id || now.timeIntervalSince($0.watchedAt) >= 7 * 86400 }
        recentWatches.insert(RecentWatch(match: saved, channelName: source.name, watchedAt: now), at: 0)
        recentWatches = Array(recentWatches.prefix(10))
        let key = source.pageURL.absoluteString
        var performance = channelPerformance[key] ?? ChannelPerformance()
        let elapsed = min(120, max(0, startup))
        performance.averageStartup = performance.successes == 0 ? elapsed
            : performance.averageStartup * 0.7 + elapsed * 0.3
        performance.successes += 1
        performance.lastFailure = nil
        performance.updatedAt = now
        channelPerformance[key] = performance
        prunePerformance(now: now)
    }

    func recordPlaybackFailure(source: MatchSource, now: Date = Date()) {
        let key = source.pageURL.absoluteString
        var performance = channelPerformance[key] ?? ChannelPerformance()
        performance.failures += 1
        performance.lastFailure = now
        performance.updatedAt = now
        channelPerformance[key] = performance
        prunePerformance(now: now)
    }

    private func prunePerformance(now: Date) {
        let kept = channelPerformance.filter { now.timeIntervalSince($0.value.updatedAt) < 30 * 86400 }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(300)
        channelPerformance = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    func rankedIndices(for sources: [MatchSource], matchID: String, now: Date = Date()) -> [Int] {
        sources.indices.sorted { lhs, rhs in
            let a = channelPerformance[sources[lhs].pageURL.absoluteString] ?? ChannelPerformance()
            let b = channelPerformance[sources[rhs].pageURL.absoluteString] ?? ChannelPerformance()
            let aCooling = a.lastFailure.map { now.timeIntervalSince($0) < 300 } ?? false
            let bCooling = b.lastFailure.map { now.timeIntervalSince($0) < 300 } ?? false
            if aCooling != bCooling { return !aCooling }
            let last = lastChannels[matchID]?.name
            let aRemembered = a.successes > 0 && sources[lhs].name == last
            let bRemembered = b.successes > 0 && sources[rhs].name == last
            if aRemembered != bRemembered { return aRemembered }
            if a.reliability != b.reliability { return a.reliability > b.reliability }
            if a.averageStartup != b.averageStartup { return a.averageStartup < b.averageStartup }
            return lhs < rhs
        }
    }

    var hasHistory: Bool {
        !favoriteTeams.isEmpty || !lastChannels.isEmpty || !recentWatches.isEmpty || !channelPerformance.isEmpty
    }

    func clearHistory() {
        favoriteTeams = []
        lastChannels = [:]
        recentWatches = []
        channelPerformance = [:]
        lastFilter = .all
    }
}
