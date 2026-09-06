import SwiftUI

struct CompactMatchListScreen: View {
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
            .navigationTitle("今日比赛")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .navigationDestination(for: LiveMatch.self) { match in
                MatchDetailScreen(match: match, preferences: preferences, autoplay: resumeMatchID == match.id)
            }
            .searchable(text: $model.searchText, prompt: "搜索球队或联赛")
            .searchSuggestions {
                if model.searchText.isEmpty {
                    ForEach(model.leagueNames.prefix(12), id: \.self) { league in
                        Text(league).searchCompletion(league)
                    }
                }
            }
        }
        .onChange(of: path.count) { _, count in if count == 0 { resumeMatchID = nil } }
        .onReceive(minuteTick) { now = $0 }
        #if DEBUG
        .onChange(of: model.isLoading) { _, loading in
            guard !loading, !model.matches.isEmpty, !appliedDebugRoute, path.isEmpty else { return }
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
                VStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { _ in TouchSkeletonRow() }
                }
                .padding(16)
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

    private var isSearching: Bool { !model.searchText.isEmpty }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10, pinnedViews: []) {
                summary
                    .padding(.horizontal, 16)

                ScoreFreshnessLine(now: now).padding(.horizontal, 16)
                if !isSearching, model.filter != .recent, let match = model.continueMatch {
                    Button { resumeMatchID = match.id; path.append(match) } label: { ContinueWatchingLabel(match: match) }
                        .buttonStyle(.plain).padding(.horizontal, 16)
                }

                if !isSearching {
                    TouchCategoryBar(
                        selection: $model.filter,
                        filters: model.availableFilters,
                        counts: model.categoryCounts
                    )
                }

                if let errorMessage = model.errorMessage {
                    TouchNotice(
                        message: "赛程刷新失败：\(errorMessage) 下面仍是上次读取的赛程。",
                        actionTitle: "重试",
                        action: { Task { await model.refresh() } }
                    )
                    .padding(.horizontal, 16)
                }

                if isSearching {
                    searchResults
                } else if model.filteredMatches.isEmpty {
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
        HStack(spacing: 8) {
            Text(summaryLine)
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
            if MatchSchedule.viewerIsOffFeedTime(now: now) {
                Label("本机时间", systemImage: "globe")
                    .font(.caption2)
                    .foregroundStyle(Palette.tertiaryText)
            }
        }
    }

    private var summaryLine: String {
        var parts = ["共 \(model.matches.count) 场"]
        let live = model.liveCount
        if live > 0 { parts.append("\(live) 场进行中") }
        if let updated = model.lastUpdated {
            parts.append("赛程 \(Self.clockFormatter.string(from: updated))")
        }
        return parts.joined(separator: " · ")
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var sections: some View {
        ForEach(model.sections) { section in
            HStack(spacing: 8) {
                if section.status.isLive { LiveBadge(compact: true) }
                Text(section.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(section.status.isLive ? Palette.live : Palette.primaryText)
                Text("\(section.matches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.tertiaryText)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            ForEach(section.matches) { match in
                NavigationLink(value: match) {
                    TouchMatchRow(match: match, now: now)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if model.visibleMatches.isEmpty {
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
                title: "这个分类今天没有比赛",
                message: "换一个分类，或下拉刷新看看最新赛程。",
                illustration: Illustration.noMatches
            )
        }
    }
}
