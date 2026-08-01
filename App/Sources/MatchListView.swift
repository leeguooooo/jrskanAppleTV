import SwiftUI

struct MatchListView: View {
    @EnvironmentObject private var model: MatchListModel

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                content
            }
            .toolbar(.hidden, for: .navigationBar)
        }
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

            CategoryBar(selection: $model.filter, counts: model.categoryCounts)
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 26)
                .padding(.bottom, 28)
                .focusSection()

            if model.filteredMatches.isEmpty {
                StatusState(
                    systemImage: "sportscourt",
                    title: "这个分类今天没有比赛",
                    message: "换一个分类，或下拉刷新看看最新赛程。"
                )
            } else {
                matchList
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                Text("今日比赛")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(Palette.primaryText)

                Text("共 \(model.matches.count) 场 · \(model.hotCount) 场热门")
                    .font(.title3)
                    .foregroundStyle(Palette.secondaryText)
            }

            Spacer()

            HStack(spacing: 18) {
                NavigationLink {
                    SearchMatchesView()
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }

                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
            .focusSection()
        }
    }

    private var matchList: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                ForEach(model.filteredMatches) { match in
                    NavigationLink {
                        MatchDetailView(match: match)
                    } label: {
                        MatchCard(match: match)
                    }
                    .buttonStyle(FocusCardButtonStyle())
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 60)
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

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(model.visibleMatches) { match in
                        NavigationLink {
                            MatchDetailView(match: match)
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
                            : "换个关键词试试，比如联赛名或球队简称。"
                    )
                }
            }
        }
        .searchable(text: $model.searchText, prompt: "搜索球队或联赛")
        .onDisappear { model.searchText = "" }
    }
}
