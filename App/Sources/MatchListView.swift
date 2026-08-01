import SwiftUI

struct MatchListView: View {
    @EnvironmentObject private var model: MatchListModel

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.matches.isEmpty {
                    ProgressView("正在获取今日比赛…")
                } else if let errorMessage = model.errorMessage, model.matches.isEmpty {
                    ContentUnavailableView {
                        Label("暂时无法载入比赛", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") {
                            Task { await model.refresh() }
                        }
                    }
                } else {
                    matchList
                }
            }
            .navigationTitle("今日比赛")
            .toolbar {
                ToolbarItem {
                    NavigationLink {
                        SearchMatchesView()
                    } label: {
                        Label("搜索", systemImage: "magnifyingglass")
                    }
                }
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
    }

    private var matchList: some View {
        List {
            Section {
                Picker("分类", selection: $model.filter) {
                    ForEach(SportFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                ForEach(model.filteredMatches) { match in
                    NavigationLink {
                        MatchDetailView(match: match)
                    } label: {
                        MatchRow(match: match)
                    }
                }
            } header: {
                Text("第 1 步 · 选择比赛（\(model.filteredMatches.count) 场）")
            } footer: {
                Text("比赛与线路来自公开网页；播放前请确认你拥有合法观看权限。")
            }
        }
        .overlay {
            if model.filteredMatches.isEmpty {
                ContentUnavailableView("当前分类没有比赛", systemImage: "sportscourt")
            }
        }
    }
}

private struct SearchMatchesView: View {
    @EnvironmentObject private var model: MatchListModel

    var body: some View {
        List(model.visibleMatches) { match in
            NavigationLink {
                MatchDetailView(match: match)
            } label: {
                MatchRow(match: match)
            }
        }
        .navigationTitle("搜索比赛")
        .searchable(text: $model.searchText, prompt: "搜索球队或联赛")
        .overlay {
            if model.visibleMatches.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
        .onDisappear {
            model.searchText = ""
        }
    }
}

private struct MatchRow: View {
    let match: LiveMatch

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(match.league)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if match.isHot {
                        Label("热门", systemImage: "flame.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(match.homeTeam)  vs  \(match.awayTeam)")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(match.time)
                    .font(.subheadline.monospacedDigit())
                Text("\(match.sources.count) 条线路")
                    .font(.caption)
                    .foregroundStyle(match.sources.isEmpty ? .red : .secondary)
            }
        }
        .frame(minHeight: 84)
        .padding(.vertical, 10)
    }
}

private struct MatchDetailView: View {
    let match: LiveMatch
    @State private var channels: [MatchSource]?
    @State private var channelErrorMessage: String?

    var body: some View {
        List {
            Section("第 1 步 · 已选择比赛") {
                VStack(alignment: .leading, spacing: 14) {
                    Text(match.league)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(match.homeTeam)
                        .font(.title2.weight(.bold))
                    Text("对阵")
                        .foregroundStyle(.secondary)
                    Text(match.awayTeam)
                        .font(.title2.weight(.bold))
                    Text(match.time)
                        .font(.headline.monospacedDigit())
                }
                .padding(.vertical)
            }

            Section {
                if match.sources.isEmpty {
                    Text("当前比赛还没有可用线路。")
                        .foregroundStyle(.secondary)
                } else if channels == nil {
                    ProgressView("正在读取主播解说与高清频道…")
                        .frame(minHeight: 78)
                } else if let channels, !channels.isEmpty {
                    ForEach(Array(channels.enumerated()), id: \.element.id) { index, source in
                        NavigationLink {
                            PlayerScreen(match: match, source: source)
                        } label: {
                            SourceRow(
                                number: index + 1,
                                source: source,
                                subtitle: source.name.localizedCaseInsensitiveContains("中文高清")
                                    ? "中文高清频道 · 选择后进入播放器"
                                    : "选择后进入播放器"
                            )
                        }
                    }
                } else {
                    if let channelErrorMessage {
                        Text(channelErrorMessage)
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(match.sources.enumerated()), id: \.element.id) { index, source in
                        NavigationLink {
                            PlayerScreen(match: match, source: source)
                        } label: {
                            SourceRow(
                                number: index + 1,
                                source: source,
                                subtitle: "备用入口 · 选择后直接尝试播放"
                            )
                        }
                    }
                }
            } header: {
                Text("第 2 步 · 选择具体频道")
            } footer: {
                Text("这里会显示主播解说①～④、中文高清 Q ⑤、高清直播⑥等频道；用遥控器向下移动并按中间键选择。")
            }
        }
        .navigationTitle("\(match.homeTeam) vs \(match.awayTeam)")
        .task(id: match.id) {
            await loadChannels()
        }
    }

    @MainActor
    private func loadChannels() async {
        channels = nil
        channelErrorMessage = nil

        for source in match.sources {
            do {
                let loadedChannels = try await SourcePageClient().fetchChannels(from: source.pageURL)
                if !loadedChannels.isEmpty {
                    channels = loadedChannels
                    return
                }
            } catch {
                continue
            }
        }

        channels = []
        channelErrorMessage = "暂时没能读取具体频道，下面保留首页备用入口。"
    }
}

private struct SourceRow: View {
    let number: Int
    let source: MatchSource
    let subtitle: String

    var body: some View {
        HStack(spacing: 18) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .frame(width: 46, height: 46)
                .background(.tint.opacity(0.22), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(source.name)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 78)
        .padding(.vertical, 8)
    }
}
