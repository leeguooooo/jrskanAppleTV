import SwiftUI

struct PhoneMatchListScreen: View {
    @EnvironmentObject private var model: MatchListModel
    @EnvironmentObject private var preferences: Preferences

    @State private var now = Date()
    @State private var path = NavigationPath()
    private let minuteTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                PhoneBackground()
                content
            }
            .navigationTitle("今日比赛")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        PhoneSettingsScreen()
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .navigationDestination(for: LiveMatch.self) { match in
                PhoneMatchDetailScreen(match: match, preferences: preferences)
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
        .onReceive(minuteTick) { now = $0 }
        #if DEBUG
        .onChange(of: model.matches.isEmpty) { _, isEmpty in
            guard !isEmpty, path.isEmpty, let target = DebugRoute.target(in: model.filteredMatches) else { return }
            path.append(target)
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.matches.isEmpty {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { _ in PhoneSkeletonRow() }
                }
                .padding(16)
            }
        } else if let errorMessage = model.errorMessage, model.matches.isEmpty {
            PhoneStatusState(
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

                if !isSearching {
                    PhoneCategoryBar(
                        selection: $model.filter,
                        filters: model.availableFilters,
                        counts: model.categoryCounts
                    )
                }

                if let errorMessage = model.errorMessage {
                    PhoneNotice(
                        message: "刷新失败：\(errorMessage) 下面仍是上次读取的赛程。",
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
            parts.append("更新于 \(Self.clockFormatter.string(from: updated))")
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
                    PhoneMatchRow(match: match, now: now)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if model.visibleMatches.isEmpty {
            PhoneStatusState(
                title: "没有匹配的比赛",
                message: "换个关键词试试，比如联赛名或球队简称。",
                illustration: Illustration.search
            )
        } else {
            ForEach(model.visibleMatches) { match in
                NavigationLink(value: match) {
                    PhoneMatchRow(match: match, now: now)
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
            PhoneStatusState(
                title: "关注的球队今天没有比赛",
                message: "在比赛详情里点「关注」可以添加更多球队。",
                illustration: Illustration.noMatches
            )
        default:
            PhoneStatusState(
                title: "这个分类今天没有比赛",
                message: "换一个分类，或下拉刷新看看最新赛程。",
                illustration: Illustration.noMatches
            )
        }
    }
}
