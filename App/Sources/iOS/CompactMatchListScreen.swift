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

    @State private var now = Date()
    @State private var path = NavigationPath()
    @State private var resumeMatchID: String?
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
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            SettingsScreen()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("设置")
                    }
                }
                .navigationDestination(for: LiveMatch.self) { match in
                    MatchDetailScreen(match: match, preferences: preferences, autoplay: resumeMatchID == match.id)
                }
        }
        .onChange(of: path.count) { _, count in if count == 0 { resumeMatchID = nil } }
        .onReceive(minuteTick) { now = $0 }
        #if DEBUG
        .onChange(of: model.isLoading) { _, loading in
            guard sport == .all, !loading, !model.matches.isEmpty, !appliedDebugRoute, path.isEmpty else { return }
            if DebugRoute.raw == "resume", let match = model.continueMatch {
                appliedDebugRoute = true
                resumeMatchID = match.id
                path.append(match)
            } else if let target = DebugRoute.target(in: model.filteredMatches) {
                appliedDebugRoute = true
                path.append(target)
            }
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.matches.isEmpty {
            List {
                Section {
                    ForEach(0..<8, id: \.self) { _ in ScoreboardPlaceholderRow() }
                }
            }
            .listStyle(.insetGrouped)
        } else if let errorMessage = model.errorMessage, model.matches.isEmpty {
            ContentUnavailableView {
                Label("暂时无法载入比赛", systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("重试") { Task { await model.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            list
        }
    }

    private var list: some View {
        List {
            if sport == .all, model.filter == .all, let match = model.continueMatch {
                Section {
                    Button { resumeMatchID = match.id; path.append(match) } label: {
                        ContinueWatchingRow(match: match)
                    }
                    .tint(.primary)
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Label {
                        Text("赛程刷新失败，下面是上次读取的赛程。\(errorMessage)")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Button("重试") { Task { await model.refresh() } }
                }
            }

            ForEach(model.sections) { section in
                Section {
                    ForEach(section.matches) { match in
                        Button { path.append(match) } label: {
                            ScoreboardRow(match: match, now: now)
                        }
                        .tint(.primary)
                        .contextMenu { FollowMenu(match: match) }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(section.title)
                        Text("\(section.matches.count)").foregroundStyle(.tertiary)
                    }
                }
                .headerProminence(.increased)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.refresh() }
        .overlay {
            if model.filteredMatches.isEmpty { emptyState }
        }
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
            Image(systemName: model.filter == .all
                  ? "line.3.horizontal.decrease"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("筛选")
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
                Text("继续观看").font(.headline)
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
