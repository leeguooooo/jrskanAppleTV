import SwiftUI

/// iPhone home: a tab per sport plus a search tab, the way Apple's own apps
/// put their top-level destinations at the bottom within thumb reach.
///
/// Tab selection is `model.filter`, so a pick survives a relaunch. Hot,
/// followed and recent are refinements of 全部 and select that tab.
struct CompactHomeScreen: View {
    @EnvironmentObject private var model: MatchListModel

    private enum Destination: Hashable {
        case sport(SportFilter)
        case search
    }

    @State private var searching = false

    private var selection: Binding<Destination> {
        Binding(
            get: {
                if searching { return .search }
                return .sport(SportFilter.tabs.contains(model.filter) ? model.filter : .all)
            },
            set: { destination in
                switch destination {
                case .search:
                    searching = true
                case .sport(let sport):
                    searching = false
                    // Re-picking 全部 while a refinement is on keeps the refinement.
                    if sport != .all || SportFilter.tabs.contains(model.filter) { model.filter = sport }
                }
            }
        )
    }

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                TabView(selection: selection) {
                    ForEach(SportFilter.tabs) { sport in
                        Tab(tabTitle(sport), systemImage: tabSymbol(sport), value: Destination.sport(sport)) {
                            CompactMatchListScreen(sport: sport)
                        }
                    }
                    Tab(value: Destination.search, role: .search) {
                        TouchSearchScreen()
                    }
                }
            } else {
                TabView(selection: selection) {
                    ForEach(SportFilter.tabs) { sport in
                        CompactMatchListScreen(sport: sport)
                            .tabItem { Label(tabTitle(sport), systemImage: tabSymbol(sport)) }
                            .tag(Destination.sport(sport))
                    }
                    TouchSearchScreen()
                        .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                        .tag(Destination.search)
                }
            }
        }
        #if DEBUG
        .onAppear {
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "-tab"), index + 1 < args.count {
                if args[index + 1] == "search" { searching = true }
                else if let sport = SportFilter(rawValue: args[index + 1]) { model.filter = sport }
            }
        }
        #endif
    }

    private func tabTitle(_ sport: SportFilter) -> String {
        sport == .all ? "比赛" : sport.rawValue
    }

    private func tabSymbol(_ sport: SportFilter) -> String {
        sport == .all ? "sportscourt.fill" : (sport.systemImage ?? "circle")
    }
}

/// The search tab: today's competitions until something is typed, then
/// matching fixtures across every sport.
struct TouchSearchScreen: View {
    @EnvironmentObject private var model: MatchListModel
    @EnvironmentObject private var preferences: Preferences
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.searchText.isEmpty {
                    Section("今天的联赛") {
                        ForEach(model.leagueNames, id: \.self) { league in
                            Button(league) { model.searchText = league }
                                .tint(.primary)
                        }
                    }
                } else {
                    ForEach(model.visibleMatches) { match in
                        Button { path.append(match) } label: { ScoreboardRow(match: match) }
                            .tint(.primary)
                            .contextMenu { FollowMenu(match: match) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if !model.searchText.isEmpty, model.visibleMatches.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("搜索")
            .navigationDestination(for: LiveMatch.self) { match in
                MatchDetailScreen(match: match, preferences: preferences, autoplay: false)
            }
            .searchable(text: $model.searchText, prompt: "球队或联赛")
        }
    }
}
