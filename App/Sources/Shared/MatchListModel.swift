import Foundation

struct MatchSection: Identifiable {
    let status: MatchStatus
    let matches: [LiveMatch]

    var id: Int { status.rank }
    var title: String { status.sectionTitle }
}

@MainActor
final class MatchListModel: ObservableObject {
    @Published private(set) var matches: [LiveMatch] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var filter: SportFilter = .all {
        didSet { preferences.lastFilter = filter }
    }

    let preferences: Preferences

    private let client: JRSClient
    private var autoRefreshTask: Task<Void, Never>?

    /// How often the schedule re-fetches itself while the list is on screen.
    static let autoRefreshInterval: TimeInterval = 5 * 60

    init(client: JRSClient = JRSClient(), preferences: Preferences? = nil) {
        self.client = client
        let preferences = preferences ?? Preferences()
        self.preferences = preferences
        self.filter = preferences.lastFilter
    }

    // MARK: - Derived lists

    var visibleMatches: [LiveMatch] {
        sortedMatches.filter { match in
            searchText.isEmpty
                || match.league.localizedCaseInsensitiveContains(searchText)
                || match.homeTeam.localizedCaseInsensitiveContains(searchText)
                || match.awayTeam.localizedCaseInsensitiveContains(searchText)
        }
    }

    var filteredMatches: [LiveMatch] {
        sortedMatches.filter { filter.includes($0, favorites: preferences.favoriteTeams) }
    }

    /// The current filter split into "on now / up next / over" groups so the
    /// viewer never has to read a clock to find something to watch.
    var sections: [MatchSection] {
        let now = Date()
        let grouped = Dictionary(grouping: filteredMatches) {
            MatchSchedule.status(for: $0, now: now).rank
        }
        return grouped
            .sorted { $0.key < $1.key }
            .compactMap { rank, matches in
                guard let first = matches.first else { return nil }
                return MatchSection(status: MatchSchedule.status(for: first, now: now), matches: matches)
            }
    }

    /// Live first, then upcoming by kickoff, then finished (latest first).
    private var sortedMatches: [LiveMatch] {
        let now = Date()
        let keyed = matches.map { match -> (LiveMatch, MatchStatus, Date) in
            (match, MatchSchedule.status(for: match, now: now),
             MatchSchedule.kickoff(from: match.time, now: now) ?? .distantFuture)
        }
        return keyed.sorted { lhs, rhs in
            if lhs.1.rank != rhs.1.rank { return lhs.1.rank < rhs.1.rank }
            // A live match with no channel cannot be watched; keep the ones
            // that can be opened ahead of it inside the same section.
            let lhsPlayable = !lhs.0.sources.isEmpty, rhsPlayable = !rhs.0.sources.isEmpty
            if lhsPlayable != rhsPlayable { return lhsPlayable }
            if case .finished = lhs.1 { return lhs.2 > rhs.2 }
            return lhs.2 < rhs.2
        }
        .map(\.0)
    }

    /// Which chips to show. "关注" only earns a slot once the viewer has
    /// actually followed a team — an always-empty category is noise.
    var availableFilters: [SportFilter] {
        SportFilter.allCases.filter { $0 != .followed || !preferences.favoriteTeams.isEmpty }
    }

    var categoryCounts: [SportFilter: Int] {
        SportFilter.allCases.reduce(into: [:]) { counts, category in
            counts[category] = matches.filter { category.includes($0, favorites: preferences.favoriteTeams) }.count
        }
    }

    var hotCount: Int {
        matches.filter(\.isHot).count
    }

    var liveCount: Int {
        let now = Date()
        return matches.filter { MatchSchedule.status(for: $0, now: now).isLive }.count
    }

    /// Distinct league names, for search suggestions.
    var leagueNames: [String] {
        var seen = Set<String>()
        return matches.map(\.league).filter { seen.insert($0).inserted }
    }

    // MARK: - Loading

    func loadIfNeeded() async {
        guard matches.isEmpty else { return }
        await refresh()
    }

    /// Foreground return: only re-fetch when the data is old enough to matter.
    func refreshIfStale(maxAge: TimeInterval = 120) async {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < maxAge { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            matches = try await client.fetchMatches()
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.autoRefreshInterval * 1_000_000_000))
                guard let self, !Task.isCancelled, self.preferences.autoRefresh else { continue }
                await self.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }
}
