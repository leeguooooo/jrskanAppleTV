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

/// The search tab: league shortcuts until something is typed, then matching
/// fixtures across every sport.
struct TouchSearchScreen: View {
    @EnvironmentObject private var model: MatchListModel
    @EnvironmentObject private var preferences: Preferences
    @State private var now = Date()

    var body: some View {
        NavigationStack {
            ZStack {
                TouchBackground()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.searchText.isEmpty {
                            leagues
                        } else if model.visibleMatches.isEmpty {
                            TouchStatusState(
                                title: "没有匹配的比赛",
                                message: "换个关键词试试，比如联赛名或球队简称。",
                                illustration: Illustration.search
                            )
                        } else {
                            ForEach(model.visibleMatches) { match in
                                NavigationLink(value: match) {
                                    TouchMatchRow(match: match, now: now)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle("搜索")
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: LiveMatch.self) { match in
                MatchDetailScreen(match: match, preferences: preferences, autoplay: false)
            }
            .searchable(text: $model.searchText, prompt: "球队或联赛")
        }
        .onAppear { now = Date() }
    }

    private var leagues: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("今天的联赛")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                ForEach(Array(model.leagueNames.enumerated()), id: \.element) { index, league in
                    if index > 0 { Divider().padding(.leading, 16) }
                    Button { model.searchText = league } label: {
                        HStack {
                            Text(league).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: TouchMetrics.corner, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .padding(.horizontal, 16)
        }
    }
}
