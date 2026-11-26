import AVKit
import SwiftUI

/// 回看 on the TV: recent recordings from Weibo, a card per game.
struct ReplaysView: View {
    @ObservedObject private var library = ReplayLibrary.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppBackground()
            if library.groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Text("回看")
                            .font(BrandFont.heading(60, relativeTo: .largeTitle))
                            .foregroundStyle(Palette.primaryText)
                        Text("录像来自微博网友上传，同一场常有好几个版本。")
                            .font(.callout).foregroundStyle(Palette.secondaryText)
                        ForEach(sections, id: \.title) { section in
                            SectionHeader(title: section.title, count: section.groups.count)
                            ForEach(section.groups) { group in
                                NavigationLink {
                                    ReplayGroupView(group: group)
                                } label: {
                                    ReplayGroupCard(group: group)
                                }
                                .buttonStyle(FocusCardButtonStyle())
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 46)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onExitCommand { dismiss() }
        .task { await library.refreshIfStale() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if library.isLoading {
            ProgressView("正在找录像…")
        } else if let error = library.errorMessage {
            StatusState(systemImage: "wifi.exclamationmark", title: "没拿到录像", message: error,
                        illustration: Illustration.offline, actionTitle: "重试",
                        action: { Task { await library.refresh() } })
        } else {
            StatusState(systemImage: "play.rectangle.on.rectangle", title: "最近没有录像",
                        message: "比赛结束后一两个小时，网友才会陆续上传。", illustration: Illustration.noMatches,
                        actionTitle: "刷新", action: { Task { await library.refresh() } })
        }
    }

    private var sections: [(title: String, groups: [ReplayGroup])] {
        var result: [(title: String, groups: [ReplayGroup])] = []
        for group in library.groups {
            let title = group.dayText()
            if let index = result.firstIndex(where: { $0.title == title }) {
                result[index].groups.append(group)
            } else {
                result.append((title, [group]))
            }
        }
        return result
    }
}

private struct ReplayGroupCard: View {
    let group: ReplayGroup

    var body: some View {
        HStack(spacing: 28) {
            TVReplayCover(url: group.videos.first?.coverURL)
                .frame(width: 192, height: 108)
            VStack(alignment: .leading, spacing: 8) {
                Text(group.title).font(.title3.weight(.bold)).foregroundStyle(Palette.primaryText)
                Text(group.partsSummary).font(.callout).foregroundStyle(Palette.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Palette.tertiaryText)
        }
        .padding(18)
    }
}

/// Opens replays in the live player (PlayerPresenter), so the transport bar
/// has the other uploads of the game and 比赛数据, like a live match.
@MainActor
final class TVReplayLauncher: ObservableObject {
    @Published private(set) var model: MatchPlaybackModel?
    @Published private(set) var openingID: String?
    @Published var errorMessage: String?
    private var task: Task<Void, Never>?

    func play(_ videos: [ReplayVideo], at index: Int, fixture: LiveMatch?, preferences: Preferences) {
        guard videos.indices.contains(index) else { return }
        task?.cancel()
        errorMessage = nil
        openingID = videos[index].id
        task = Task {
            defer { if !Task.isCancelled { openingID = nil } }
            var fixture = fixture
            if fixture == nil { fixture = await ReplayFixture.nbaMatch(for: videos) }
            guard !Task.isCancelled else { return }
            let model = MatchPlaybackModel.replay(videos, fixture: fixture, preferences: preferences)
            self.model = model
            await model.startPlayback(at: index)
            if model.playback == nil { errorMessage = model.errorMessage ?? "这个视频暂时打不开。" }
        }
    }

    func stop() {
        model?.stopPlayback()
        if let message = model?.errorMessage { errorMessage = message }
        model = nil
    }
}

/// Hosts the live player for a replay model.
private struct TVReplayPlayer: View {
    @ObservedObject var model: MatchPlaybackModel
    let onStop: () -> Void

    var body: some View {
        PlayerPresenter(
            request: $model.playback,
            match: model.match,
            insights: model.insights,
            channels: model.resolvedChannels,
            onSelectChannel: { index in Task { await model.startManualPlayback(at: index) } },
            onStall: { id, message in model.handleStall(message, requestID: id) },
            onConfirmed: { id, startup in model.confirmPlayback(requestID: id, startupSeconds: startup) },
            onStop: onStop,
            isReplay: true,
            onPosition: { seconds, duration in model.reportPosition(seconds, duration: duration) },
            onFinished: { model.replayFinished() }
        )
    }
}

private struct TVReplayPlayerHost: View {
    @ObservedObject var launcher: TVReplayLauncher

    var body: some View {
        if let model = launcher.model {
            TVReplayPlayer(model: model, onStop: { launcher.stop() })
        }
    }
}

/// Every upload of one game; picking one plays it.
struct ReplayGroupView: View {
    let group: ReplayGroup
    @StateObject private var launcher = TVReplayLauncher()
    @EnvironmentObject private var preferences: Preferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text(group.title)
                        .font(BrandFont.heading(54, relativeTo: .largeTitle))
                        .foregroundStyle(Palette.primaryText)
                    Text("\(group.dayText()) · \(group.videos.count) 个视频")
                        .font(.callout).foregroundStyle(Palette.secondaryText)
                    if let error = launcher.errorMessage { Text(error).foregroundStyle(Palette.live) }
                    ForEach(Array(group.videos.enumerated()), id: \.element.id) { index, video in
                        Button {
                            launcher.play(group.videos, at: index, fixture: nil, preferences: preferences)
                        } label: {
                            TVReplayVideoCard(video: video, isOpening: launcher.openingID == video.id)
                        }
                        .buttonStyle(FocusCardButtonStyle())
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 46)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onExitCommand { dismiss() }
        .background(TVReplayPlayerHost(launcher: launcher))
    }
}

struct TVReplayVideoCard: View {
    let video: ReplayVideo
    var isOpening = false

    var body: some View {
        HStack(spacing: 28) {
            TVReplayCover(url: video.coverURL)
                .frame(width: 192, height: 108)
            VStack(alignment: .leading, spacing: 6) {
                Text(video.part.label).font(.title3.weight(.bold)).foregroundStyle(Palette.primaryText)
                Text(video.title).font(.callout).foregroundStyle(Palette.secondaryText).lineLimit(1)
                Text(detail)
                    .font(.caption.monospacedDigit()).foregroundStyle(Palette.tertiaryText)
            }
            Spacer()
            if isOpening {
                ProgressView()
            } else {
                Image(systemName: "play.fill").foregroundStyle(Palette.accent)
            }
        }
        .padding(18)
    }
}

extension TVReplayVideoCard {
    private var detail: String {
        var parts = [ReplayVideo.durationText(video.duration), video.author]
        if let resume = ReplayResume.position(for: video.id) { parts.append("看到 \(ReplayVideo.durationText(resume))") }
        return parts.joined(separator: " · ")
    }
}

private struct TVReplayCover: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Palette.surface.overlay(Image(systemName: "play.rectangle").foregroundStyle(Palette.tertiaryText))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 回放 rows on the TV match screen, once the match is over.
struct MatchReplayRows: View {
    @StateObject private var replays: MatchReplays
    @StateObject private var launcher = TVReplayLauncher()
    @EnvironmentObject private var preferences: Preferences

    init(match: LiveMatch) {
        _replays = StateObject(wrappedValue: MatchReplays(match: match))
    }

    var body: some View {
        if MatchReplays.isEligible(replays.match) {
            VStack(alignment: .leading, spacing: 18) {
                Text("回放").font(.title3.weight(.bold)).foregroundStyle(Palette.primaryText)
                if let error = launcher.errorMessage { Text(error).foregroundStyle(Palette.live) }
                switch replays.state {
                case .idle, .loading:
                    HStack(spacing: 16) { ProgressView(); Text("正在找录像…") }
                case .failed(let message):
                    Button { Task { await replays.load() } } label: { Label("\(message) 重试", systemImage: "arrow.clockwise") }
                case .loaded where replays.videos.isEmpty:
                    Text("还没有人上传这场的录像，过一两个小时再来看看。").foregroundStyle(Palette.secondaryText)
                case .loaded:
                    ForEach(Array(replays.videos.prefix(6).enumerated()), id: \.element.id) { index, video in
                        Button {
                            launcher.play(replays.videos, at: index, fixture: replays.match, preferences: preferences)
                        } label: {
                            TVReplayVideoCard(video: video, isOpening: launcher.openingID == video.id)
                        }
                        .buttonStyle(FocusCardButtonStyle())
                    }
                }
            }
            .task { if replays.state == .idle { await replays.load() } }
            .background(TVReplayPlayerHost(launcher: launcher))
        }
    }
}
