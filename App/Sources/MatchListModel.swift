import Foundation

@MainActor
final class MatchListModel: ObservableObject {
    @Published private(set) var matches: [LiveMatch] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var filter: SportFilter = .all

    private let client: JRSClient

    init(client: JRSClient = JRSClient()) {
        self.client = client
    }

    var visibleMatches: [LiveMatch] {
        filteredMatches.filter { match in
                searchText.isEmpty
                || match.league.localizedCaseInsensitiveContains(searchText)
                || match.homeTeam.localizedCaseInsensitiveContains(searchText)
                || match.awayTeam.localizedCaseInsensitiveContains(searchText)
        }
    }

    var filteredMatches: [LiveMatch] {
        matches.filter(filter.includes)
    }

    /// Per-category totals for the browse header's category chips.
    var categoryCounts: [SportFilter: Int] {
        SportFilter.allCases.reduce(into: [:]) { counts, category in
            counts[category] = matches.filter(category.includes).count
        }
    }

    var hotCount: Int {
        matches.filter(\.isHot).count
    }

    func loadIfNeeded() async {
        guard matches.isEmpty else { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            matches = try await client.fetchMatches()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
