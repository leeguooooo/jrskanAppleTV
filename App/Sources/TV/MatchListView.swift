import SwiftUI

struct MatchListView: View {
    @EnvironmentObject private var model: MatchListModel
    @EnvironmentObject private var preferences: Preferences

    /// Re-evaluates "已进行 N 分钟" and moves matches between sections as
    /// kickoff passes, without a network refresh.
    @State private var now = Date()
    private let minuteTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                content
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onReceive(minuteTick) { now = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.matches.isEmpty {
            loadingState
        } else if let errorMessage = model.errorMessage, model.matches.isEmpty {
            StatusState(
                systemImage: "wifi.exclamationmark",
                title: "暂时无法载入比赛",
                message: errorMessage,
                illustration: Illustration.offline,
                actionTitle: "重试",
                action: { Task { await model.refresh() } }
            )
        } else {
            browse
        }
    }

    // MARK: - Browse

    private var browse: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 40)

            controlRow
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 26)
                .padding(.bottom, 18)
                .focusSection()

            if let errorMessage = model.errorMessage {
                NoticeBanner(
                    message: "刷新失败：\(errorMessage) 下面仍是上次读取的赛程。",
                    tone: .warning,
                    actionTitle: "重试",
                    action: { Task { await model.refresh() } }
                )
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 12)
            }

            if model.filteredMatches.isEmpty {
                emptyFilterState
            } else {
                matchList
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日比赛")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(Palette.primaryText)

            HStack(spacing: 14) {
                Text(summaryLine)
                    .font(.title3)
                    .foregroundStyle(Palette.secondaryText)

                if MatchSchedule.viewerIsOffFeedTime(now: now) {
                    MetaPill(text: "已换算为本机时间", systemImage: "globe", tint: Palette.tertiaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryLine: String {
        var parts = ["共 \(model.matches.count) 场"]
        let live = model.liveCount
        if live > 0 { parts.append("\(live) 场进行中") }
        if model.hotCount > 0 { parts.append("\(model.hotCount) 场热门") }
        if let updated = model.lastUpdated {
            parts.append("更新于 \(Self.clockFormatter.string(from: updated))")
        }
        return parts.joined(separator: " · ")
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Search, refresh and settings sit on the same row as the category chips
    /// on purpose. Parked in the header's top-right corner they rendered fine
    /// but were unreachable: pressing Up from the left-most chip finds only
    /// the non-focusable title above it, so the focus engine never travelled
    /// to them and the buttons read as missing. Same row means Right gets there.
    private var controlRow: some View {
        HStack(spacing: 18) {
            CategoryBar(
                selection: $model.filter,
                filters: model.availableFilters,
                counts: model.categoryCounts
            )

            Spacer(minLength: 24)

            NavigationLink {
                SearchMatchesView()
            } label: {
                HeaderIconButton(systemImage: "magnifyingglass", title: "搜索")
            }
            .buttonStyle(BareButtonStyle())

            Button {
                Task { await model.refresh() }
            } label: {
                HeaderIconButton(systemImage: "arrow.clockwise", title: "刷新", isBusy: model.isLoading)
            }
            .buttonStyle(BareButtonStyle())
            .disabled(model.isLoading)

            NavigationLink {
                SettingsView(preferences: preferences)
            } label: {
                HeaderIconButton(systemImage: "gearshape.fill", title: "设置")
            }
            .buttonStyle(BareButtonStyle())
        }
    }

    private var matchList: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                ForEach(model.sections) { section in
                    SectionHeader(
                        title: section.title,
                        count: section.matches.count,
                        isLive: section.status.isLive
                    )
                    ForEach(section.matches) { match in
                        NavigationLink {
                            MatchDetailView(match: match, preferences: preferences)
                        } label: {
                            MatchCard(match: match, now: now)
                        }
                        .buttonStyle(FocusCardButtonStyle())
                    }
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 6)
            .padding(.bottom, 60)
        }
    }

    @ViewBuilder
    private var emptyFilterState: some View {
        switch model.filter {
        case .followed:
            StatusState(
                systemImage: "star",
                title: "关注的球队今天没有比赛",
                message: "在比赛详情里按「关注」可以添加更多球队。",
                illustration: Illustration.noMatches
            )
        default:
            StatusState(
                systemImage: "sportscourt",
                title: "这个分类今天没有比赛",
                message: "换一个分类，或刷新看看最新赛程。",
                illustration: Illustration.noMatches,
                actionTitle: "刷新",
                action: { Task { await model.refresh() } }
            )
        }
    }

    // MARK: - Loading

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("今日比赛")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(Palette.primaryText)
                .padding(.bottom, 30)

            ForEach(0..<5, id: \.self) { _ in
                MatchSkeletonRow()
            }

            Spacer()
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 40)
    }
}

// MARK: - Search

private struct SearchMatchesView: View {
    @EnvironmentObject private var model: MatchListModel
    @EnvironmentObject private var preferences: Preferences

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(model.visibleMatches) { match in
                        NavigationLink {
                            MatchDetailView(match: match, preferences: preferences)
                        } label: {
                            MatchCard(match: match)
                        }
                        .buttonStyle(FocusCardButtonStyle())
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 30)
            }
            .overlay {
                if model.visibleMatches.isEmpty {
                    StatusState(
                        systemImage: "magnifyingglass",
                        title: "没有匹配的比赛",
                        message: model.searchText.isEmpty
                            ? "输入球队名或联赛名开始搜索。"
                            : "换个关键词试试，比如联赛名或球队简称。",
                        illustration: Illustration.search
                    )
                }
            }
        }
        .searchable(text: $model.searchText, prompt: "搜索球队或联赛")
        .searchSuggestions {
            // League names as one-press completions: typing on a TV keyboard
            // is the slowest thing a viewer does, so make the common case a
            // single click.
            ForEach(model.leagueNames.prefix(10), id: \.self) { league in
                Text(league).searchCompletion(league)
            }
        }
        .onExitCommand { dismiss() }
        .onDisappear { model.searchText = "" }
    }
}
