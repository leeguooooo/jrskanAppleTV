import SwiftUI

/// One sport's list inside the iPhone tab bar. Each tab keeps its own
/// navigation stack, so switching sports does not lose an open match.
///
/// Built from stock parts — an inset-grouped List, system section headers,
/// ContentUnavailableView — so it reads like an Apple app rather than a
/// themed one.
struct CompactMatchListScreen: View {
    let sport: SportFilter

    @EnvironmentObject private var model: MatchListModel
    @EnvironmentObject private var preferences: Preferences
    @ObservedObject private var appConfig = AppConfigStore.shared
    @ObservedObject private var recordings = RecordingCenter.shared
    @ObservedObject private var handoff = LayoutHandoff.shared

    @State private var now = Date()
    @State private var path: [MatchRoute] = []
    #if DEBUG
    @State private var appliedDebugRoute = false
    #endif

    private let minuteTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
                .modifier(NavigationSubtitle(text: subtitle))
                .toolbar {
                    if sport == .all {
                        ToolbarItem(placement: .topBarTrailing) { refinementMenu }
                    }
                    if !recordings.recordings.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink {
                                RecordingsScreen()
                            } label: {
                                // A title as well as a symbol: iPhone Duo puts bars on the side
                                // and moves items into an overflow menu, which shows the title.
                                Label("录像", systemImage: recordings.active.isEmpty ? "film.stack" : "record.circle")
                                    .foregroundStyle(recordings.active.isEmpty ? Palette.accent : Palette.live)
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            SettingsScreen()
                        } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                    }
                }
                .navigationDestination(for: MatchRoute.self) { route in
                    MatchDetailScreen(match: route.match, preferences: preferences, autoplay: route.autoplay)
                }
        }
        .onReceive(minuteTick) { now = $0 }
        .onAppear(perform: adoptHandoff)
        .onChange(of: handoff.pending) { _, _ in adoptHandoff() }
        .onChange(of: path) { _, _ in reportOpenMatch() }
        .onChange(of: model.filter) { _, _ in reportOpenMatch() }
        #if DEBUG
        .onChange(of: model.isLoading) { _, loading in
            guard sport == .all, !loading, !model.matches.isEmpty, !appliedDebugRoute, path.isEmpty else { return }
            if DebugRoute.raw == "resume", let match = model.continueMatch {
                appliedDebugRoute = true
                path.append(MatchRoute(match: match))
            } else if let target = DebugRoute.target(in: model.filteredMatches) {
                appliedDebugRoute = true
                path.append(MatchRoute(match: target))
            }
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.matches.isEmpty {
            List {
                Section {
                    ForEach(0..<8, id: \.self) { _ in ScoreboardPlaceholderRow().scoreboardRow() }
                }
            }
            .listStyle(.insetGrouped)
            .scoreboardList()
        } else if let errorMessage = model.errorMessage, model.matches.isEmpty {
            ContentUnavailableView {
                Label("暂时无法载入比赛", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("重试") { Task { await model.refresh() } }
                    .buttonStyle(AmberButtonStyle())
            }
            .background(TouchBackground())
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if sport == .all, let banner = appConfig.slot("home_banner") {
                Section { ConfigBanner(slot: banner).scoreboardRow() }
            }

            if let hero {
                Section {
                    Button { path.append(MatchRoute(match: hero)) } label: {
                        LiveHeroCard(match: hero, now: now)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { FollowMenu(match: hero) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            if sport == .all, model.filter == .all, let match = model.continueMatch {
                Section {
                    Button { path.append(MatchRoute(match: match)) } label: {
                        ContinueWatchingRow(match: match)
                    }
                    .tint(.primary)
                    .scoreboardRow()
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Label {
                        Text("赛程刷新失败，下面是上次读取的赛程。\(errorMessage)")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.accent)
                    }
                    .scoreboardRow()
                    Button("重试") { Task { await model.refresh() } }
                        .scoreboardRow()
                }
            }

            ForEach(model.sections) { section in
                let rows = section.matches.filter { $0.id != hero?.id }
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { match in
                            Button { path.append(MatchRoute(match: match)) } label: {
                                ScoreboardRow(match: match, now: now)
                            }
                            .tint(.primary)
                            .contextMenu { FollowMenu(match: match) }
                            .scoreboardRow()
                        }
                    } header: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(section.title)
                                .font(BrandFont.heading(21, relativeTo: .title3))
                                .foregroundStyle(Palette.primaryText)
                            Text("\(section.matches.count)")
                                .font(BrandFont.numeric(15, relativeTo: .subheadline))
                                .foregroundStyle(Palette.tertiaryText)
                        }
                        .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scoreboardList()
        .refreshable { await model.refresh() }
        .overlay {
            if model.filteredMatches.isEmpty { emptyState }
        }
    }

    /// Leads the 全部 list and each sport tab; refinements (关注, 热门 …) stay a plain list.
    private var hero: LiveMatch? {
        SportFilter.tabs.contains(model.filter) ? model.sections.heroMatch(now: now) : nil
    }

    /// Every sport has a tab of its own; 热门 / 关注 / 最近观看 live under 全部.
    private var isShownTab: Bool {
        (SportFilter.tabs.contains(model.filter) ? model.filter : .all) == sport
    }

    private func reportOpenMatch() {
        if isShownTab { handoff.openMatch = path.last?.match }
    }

    /// Reopen what the split view had open, without starting it again: if it
    /// is still playing, the detail screen picks up the session's model.
    private func adoptHandoff() {
        guard isShownTab, handoff.pending != nil, let match = handoff.take() else { return }
        path = [MatchRoute(match: match, autoplay: false)]
    }

    private var title: String {
        switch model.filter {
        case .all: return "今日比赛"
        case let filter where sport == .all: return filter.rawValue
        default: return sport.rawValue
        }
    }

    /// Counts follow the tab, and a score-feed problem replaces the timestamp.
    private var subtitle: String {
        let shown = model.filteredMatches
        let live = shown.filter { MatchSchedule.status(for: $0, now: now).isLive }.count
        var parts: [String] = []
        if live > 0 { parts.append("\(live) 场进行中") }
        parts.append("共 \(shown.count) 场")
        if let notice = model.scoreNotice {
            parts.append(notice)
        } else if let updated = model.scoresUpdatedAt ?? model.lastUpdated {
            // The score feed goes quiet when nothing is on; only call it stale
            // while there are games it should be updating.
            let stale = live > 0 && model.scoresUpdatedAt != nil && now.timeIntervalSince(updated) > 120
            parts.append(stale ? "比分数据较旧" : "\(Self.clock.string(from: updated)) 更新")
        }
        return parts.joined(separator: " · ")
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 热门 / 关注 / 最近观看 narrow 全部 rather than being tabs of their own.
    private var refinementMenu: some View {
        Menu {
            Picker("显示", selection: $model.filter) {
                Text("全部比赛").tag(SportFilter.all)
                ForEach(model.availableFilters.filter { !SportFilter.tabs.contains($0) }) { filter in
                    Label("\(filter.rawValue)  \(model.categoryCounts[filter] ?? 0)",
                          systemImage: filter.systemImage ?? "circle")
                        .tag(filter)
                }
            }
        } label: {
            Label("筛选", systemImage: model.filter == .all
                  ? "line.3.horizontal.decrease"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.filter {
        case .followed:
            ContentUnavailableView(
                "关注的球队今天没有比赛",
                systemImage: "star",
                description: Text("长按任意比赛可以关注球队。")
            )
        default:
            ContentUnavailableView(
                sport == .all ? "今天没有比赛" : "今天没有\(sport.rawValue)比赛",
                systemImage: sport == .all ? "sportscourt" : (sport.systemImage ?? "sportscourt"),
                description: Text("下拉刷新看看最新赛程。")
            )
        }
    }
}

struct ContinueWatchingRow: View {
    let match: LiveMatch

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.circle.fill")
                .font(.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("继续观看").font(.headline).foregroundStyle(Palette.primaryText)
                Text("\(match.homeTeam) vs \(match.awayTeam)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The large-title subtitle is new in iOS 26; earlier systems show the title alone.
struct NavigationSubtitle: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.navigationSubtitle(text)
        } else {
            content
        }
    }
}

/// A match pushed onto a tab's stack. A match reopened after a layout switch
/// shows its detail without starting playback again.
struct MatchRoute: Hashable {
    let match: LiveMatch
    var autoplay = true
}
