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
                Text("\(model.filteredMatches.count) 场")
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

    var body: some View {
        List {
            Section {
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

            Section("选择线路") {
                if match.sources.isEmpty {
                    Text("当前比赛还没有可用线路。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(match.sources) { source in
                        NavigationLink {
                            PlayerScreen(match: match, source: source)
                        } label: {
                            Label(source.name, systemImage: "play.rectangle.fill")
                        }
                    }
                }
            }
        }
        .navigationTitle("\(match.homeTeam) vs \(match.awayTeam)")
    }
}
