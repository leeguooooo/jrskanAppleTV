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

    var hasHistory: Bool {
        !favoriteTeams.isEmpty || !lastChannels.isEmpty
    }

    func clearHistory() {
        favoriteTeams = []
        lastChannels = [:]
        lastFilter = .all
    }
}
