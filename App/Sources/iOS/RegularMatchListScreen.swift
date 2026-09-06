import SwiftUI

/// Wide layout for iPad and Mac: categories in the sidebar, the schedule in
/// the middle, the selected match on the right. The middle column lays its
/// cards out in an adaptive grid, so a full-width iPad shows two per row and a
/// half-screen window falls back to one without a separate code path.
struct RegularMatchListScreen: View {
    @EnvironmentObject private var model: MatchListModel
    @EnvironmentObject private var preferences: Preferences

    @State private var now = Date()
    @State private var selection: LiveMatch?
    @State private var showsSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private let minuteTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } content: {
            schedule
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .onReceive(minuteTick) { now = $0 }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                SettingsScreen()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showsSettings = false }
                        }
                    }
            }
        }
        // Selecting a category should not leave the previous match on the
        // right: it usually is not in the new list, and the two panes then
        // disagree about what is selected.
        .onChange(of: model.filter) { _, _ in selection = nil }
        #if DEBUG
        .onChange(of: model.matches.isEmpty) { _, isEmpty in
            guard !isEmpty, selection == nil,
                  let target = DebugRoute.target(in: model.filteredMatches) else { return }
            selection = target
        }
        #endif
    }

    // MARK: - Sidebar

    /// `List(selection:)` on iOS only takes an optional binding, while the
    /// model's filter always has a value; tapping the selected row again hands
    /// back nil, which should keep the current category rather than clear it.
    private var filterSelection: Binding<SportFilter?> {
        Binding(get: { model.filter }, set: { value in if let value { model.filter = value } })
    }

    private var sidebar: some View {
        List(selection: filterSelection) {
            Section("分类") {
                ForEach(model.availableFilters) { filter in
                    Label {
                        Text(filter.rawValue)
                    } icon: {
                        Image(systemName: filter.systemImage ?? "sportscourt")
                    }
                    .badge(model.categoryCounts[filter] ?? 0)
                    .tag(filter)
                }
            }
        }
        .navigationTitle("JRKAN")
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        .toolbar {
            ToolbarItem {
                Button {
                    showsSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape.fill")
                }
            }
        }
    }

    // MARK: - Schedule

    private var schedule: some View {
        ZStack {
            TouchBackground()
            scheduleContent
        }
        .navigationTitle(model.filter == .all ? "今日比赛" : model.filter.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationSplitViewColumnWidth(min: 380, ideal: 520)
        .searchable(text: $model.searchText, placement: .navigationBarDrawer, prompt: "搜索球队或联赛")
        .searchSuggestions {
            if model.searchText.isEmpty {
                ForEach(model.leagueNames.prefix(12), id: \.self) { league in
                    Text(league).searchCompletion(league)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
        }
    }

    @ViewBuilder
    private var scheduleContent: some View {
        if model.isLoading && model.matches.isEmpty {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(0..<8, id: \.self) { _ in TouchSkeletonRow() }
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

    /// One card per row in a narrow pane, more as it widens. `.adaptive` does
    /// the counting, so multitasking and window resizing need no extra code.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 360), spacing: 12, alignment: .top)]
    }

    private var isSearching: Bool { !model.searchText.isEmpty }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                summary.padding(.horizontal, 16)

                if let errorMessage = model.errorMessage {
                    TouchNotice(
                        message: "刷新失败：\(errorMessage) 下面仍是上次读取的赛程。",
                        actionTitle: "重试",
                        action: { Task { await model.refresh() } }
                    )
                    .padding(.horizontal, 16)
                }

                if isSearching {
                    grid(of: model.visibleMatches, emptyTitle: "没有匹配的比赛",
                         emptyMessage: "换个关键词试试，比如联赛名或球队简称。",
                         illustration: Illustration.search)
                } else if model.filteredMatches.isEmpty {
                    emptyFilterState
                } else {
                    ForEach(model.sections) { section in
                        sectionHeader(section)
                        grid(of: section.matches, emptyTitle: "", emptyMessage: nil, illustration: nil)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private func grid(of matches: [LiveMatch], emptyTitle: String,
                      emptyMessage: String?, illustration: String?) -> some View {
        if matches.isEmpty, !emptyTitle.isEmpty {
            TouchStatusState(title: emptyTitle, message: emptyMessage, illustration: illustration)
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(matches) { match in
                    Button {
                        selection = match
                    } label: {
                        TouchMatchRow(match: match, now: now)
                            .overlay(
                                RoundedRectangle(cornerRadius: TouchMetrics.corner, style: .continuous)
                                    .strokeBorder(Palette.accent, lineWidth: selection == match ? 2 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func sectionHeader(_ section: MatchSection) -> some View {
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
        .padding(.top, 8)
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
            Spacer()
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

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selection {
            MatchDetailScreen(match: selection, preferences: preferences)
                // Rebuild the screen (and its playback model) when the viewer
                // picks a different match; without an identity the pane keeps
                // the first match's channels.
                .id(selection.id)
        } else {
            ZStack {
                TouchBackground()
                VStack(spacing: 16) {
                    Image("BrandMark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 72)
                        .opacity(0.85)
                    Text("选择一场比赛")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.primaryText)
                    Text("左侧选分类，中间选比赛，这里挑线路开播。")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
        }
    }
}
