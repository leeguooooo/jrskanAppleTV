import SwiftUI

/// One sport's list inside the iPhone tab bar. Each tab keeps its own
/// navigation stack, so switching sports does not lose an open match.
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
            ZStack {
                TouchBackground()
                content
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
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
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(0..<6, id: \.self) { _ in TouchSkeletonRow() }
                }
                .padding(.horizontal, 16)
            }
        } else if let errorMessage = model.errorMessage, model.matches.isEmpty {
            TouchStatusState(
                title: "暂时无法载入比赛",
                message: errorMessage,
                illustration: Illustration.offline,
                actionTitle: "重试",
                action: { Task { await model.refresh() } }
            )
        } else {
            list
        }
    }

    private var title: String {
        switch model.filter {
        case .all: return "今日比赛"
        case let filter where sport == .all: return filter.rawValue
        default: return sport.rawValue
        }
    }

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

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                summary
                    .padding(.horizontal, 16)

                if sport == .all, model.filter == .all, let match = model.continueMatch {
                    Button { resumeMatchID = match.id; path.append(match) } label: { TouchContinueWatching(match: match) }
                        .buttonStyle(.plain).padding(.horizontal, 16)
                }

                if let errorMessage = model.errorMessage {
                    TouchNotice(
                        message: "赛程刷新失败：\(errorMessage) 下面仍是上次读取的赛程。",
                        actionTitle: "重试",
                        action: { Task { await model.refresh() } }
                    )
                    .padding(.horizontal, 16)
                }

                if model.filteredMatches.isEmpty {
                    emptyFilterState
                } else {
                    sections
                }
            }
            .padding(.bottom, 32)
        }
        .refreshable { await model.refresh() }
    }

    private var summary: some View {
        TouchListSummary(now: now)
    }

    private var sections: some View {
        // A real Section per group: with header and rows as loose siblings,
        // a match moving from 其他 to 正在进行 kept its stale pre-score row.
        ForEach(model.sections) { section in
            Section {
                ForEach(section.matches) { match in
                    NavigationLink(value: match) {
                        TouchMatchRow(match: match, now: now)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                }
            } header: {
                TouchSectionHeader(section: section)
            }
        }
    }

    @ViewBuilder
    private var emptyFilterState: some View {
        switch model.filter {
        case .followed:
            TouchStatusState(
                title: "关注的球队今天没有比赛",
                message: "在比赛详情里点「关注」可以添加更多球队。",
                illustration: Illustration.noMatches
            )
        default:
            TouchStatusState(
                title: sport == .all ? "这个分类今天没有比赛" : "今天没有\(sport.rawValue)比赛",
                message: "下拉刷新看看最新赛程，或者换个项目。",
                illustration: Illustration.noMatches
            )
        }
    }
}
