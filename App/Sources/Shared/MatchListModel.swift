import Foundation

struct MatchSection: Identifiable {
    let status: MatchStatus
    let matches: [LiveMatch]
    var titleOverride: String? = nil

    var id: Int { status.rank }
    var title: String { titleOverride ?? status.sectionTitle }
}

@MainActor
final class MatchListModel: ObservableObject {
    @Published private(set) var matches: [LiveMatch] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var scoresUpdatedAt: Date?
    @Published private(set) var scoreNotice: String?
    @Published private(set) var isRefreshingScores = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var filter: SportFilter = .all {
        didSet { preferences.lastFilter = filter }
    }

    let preferences: Preferences

    private let client: JRSClient
    private var autoRefreshTask: Task<Void, Never>?
    private var scheduleMatches: [LiveMatch] = []
    private var eventURL: URL?
    private var scoreFailures = 0
    private var lastScoreAttempt: Date?

    /// How often the schedule re-fetches itself while the list is on screen.
    static let autoRefreshInterval: TimeInterval = 5 * 60
    static let scoreRefreshInterval: TimeInterval = 30

    init(client: JRSClient = JRSClient(), preferences: Preferences? = nil) {
        self.client = client
        let preferences = preferences ?? Preferences()
        self.preferences = preferences
        self.filter = preferences.lastFilter == .recent && preferences.recentWatches.isEmpty ? .all : preferences.lastFilter
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
        if filter == .recent { return recentMatches }
        return sortedMatches.filter { filter.includes($0, favorites: preferences.favoriteTeams) }
    }

    var recentMatches: [LiveMatch] {
        preferences.recentWatches.map { saved in
            matches.first { $0.id == saved.match.id } ?? saved.match
        }
    }

    var continueMatch: LiveMatch? {
        recentMatches.first { recent in
            matches.contains { $0.id == recent.id } && !recent.sources.isEmpty
                && MatchSchedule.status(for: recent) != .finished
        }
    }

    /// The current filter split into "on now / up next / over" groups so the
    /// viewer never has to read a clock to find something to watch.
    var sections: [MatchSection] {
        if filter == .recent {
            return recentMatches.isEmpty ? [] : [MatchSection(status: .unknown, matches: recentMatches, titleOverride: "最近观看")]
        }
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
        SportFilter.allCases.filter {
            ($0 != .followed || !preferences.favoriteTeams.isEmpty)
                && ($0 != .recent || !preferences.recentWatches.isEmpty)
        }
    }

    var categoryCounts: [SportFilter: Int] {
        SportFilter.allCases.reduce(into: [:]) { counts, category in
            counts[category] = category == .recent ? recentMatches.count
                : matches.filter { category.includes($0, favorites: preferences.favoriteTeams) }.count
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
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < maxAge {
            if scoresUpdatedAt == nil || Date().timeIntervalSince(scoresUpdatedAt!) >= Self.scoreRefreshInterval {
                await refreshScores()
            }
        } else { await refresh() }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let schedule = try await client.fetchSchedule()
            try Task.checkCancellation()
            scheduleMatches = schedule.matches
            if let endpoint = schedule.eventURL { eventURL = endpoint }
            // Keep the last known scores while the independent event request runs
            // or fails. Their source timestamp does not change with the schedule.
            let previous = matches.reduce(into: [String: ProviderMatchState]()) {
                if let state = $1.providerState { $0[$1.id] = state }
            }
            matches = scheduleMatches.map { raw in
                var match = raw
                match.providerState = previous[raw.id]
                return match
            }
            lastUpdated = Date()
            await refreshScores()
        } catch {
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
            await refreshScores()
        }
    }

    func refreshScores() async {
        guard !isRefreshingScores else { return }
        guard let eventURL else {
            scoreNotice = "比分暂不可用"
            return
        }
        isRefreshingScores = true
        lastScoreAttempt = Date()
        defer { isRefreshingScores = false }
        do {
            let snapshot = try await client.fetchEvents(from: eventURL)
            try Task.checkCancellation()
            // An older CDN response must not overwrite a newer score snapshot.
            guard scoresUpdatedAt == nil || snapshot.updatedAt >= scoresUpdatedAt! else { return }
            matches = snapshot.applying(to: scheduleMatches)
            scoresUpdatedAt = snapshot.updatedAt
            scoreNotice = nil
            scoreFailures = 0
        } catch {
            if Task.isCancelled { return }
            scoreFailures += 1
            scoreNotice = scoresUpdatedAt == nil ? "比分暂不可用" : "比分更新失败，显示上次数据"
        }
    }

    func scoreUpdateText(now: Date = Date()) -> String {
        if isRefreshingScores && scoresUpdatedAt == nil { return "正在载入比分…" }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        let timestamp = scoresUpdatedAt.map { clock.string(from: $0) }
        if let scoreNotice { return scoreNotice + (timestamp.map { " · \($0)" } ?? "") }
        guard let scoresUpdatedAt, let timestamp else { return "比分暂不可用" }
        return (now.timeIntervalSince(scoresUpdatedAt) > 120 ? "比分数据较旧 · " : "比分更新 · ") + timestamp
    }

    func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.scoreRefreshInterval * 1_000_000_000))
                guard let self, !Task.isCancelled, self.preferences.autoRefresh else { continue }
                let now = Date()
                if self.lastUpdated == nil || now.timeIntervalSince(self.lastUpdated!) >= Self.autoRefreshInterval {
                    await self.refresh()
                } else {
                    let delay = min(Self.autoRefreshInterval, Self.scoreRefreshInterval * pow(2, Double(min(self.scoreFailures, 4))))
                    if self.lastScoreAttempt == nil || now.timeIntervalSince(self.lastScoreAttempt!) >= delay {
                        await self.refreshScores()
                    }
                }
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }
}
