import AVKit
import SwiftUI

/// Opens a replay in the live player (PlayerSession), so it gets the same
/// furniture: AirPlay, Picture in Picture, 数据, dimming, disguise.
/// Resolve first, present second, as for live matches.
@MainActor
final class ReplayLauncher: ObservableObject {
    static let shared = ReplayLauncher()

    /// The upload whose link is being fetched.
    @Published private(set) var openingID: String?
    @Published var errorMessage: String?
    /// iPad and Mac show 回看 in a sheet, and the player cover hangs off
    /// RootScreen, which cannot present over a sheet. The sheet closes first.
    @Published private(set) var waitsForSheet = false
    var sheetIsUp = false
    private var pending: MatchPlaybackModel?
    private var task: Task<Void, Never>?

    func play(_ videos: [ReplayVideo], at index: Int, fixture: LiveMatch?, preferences: Preferences) {
        guard videos.indices.contains(index) else { return }
        task?.cancel()
        errorMessage = nil
        openingID = videos[index].id
        task = Task {
            defer { if !Task.isCancelled { openingID = nil } }
            let fixture = await fixture.asyncOr { await ReplayFixture.nbaMatch(for: videos) }
            guard !Task.isCancelled else { return }
            let model = MatchPlaybackModel.replay(videos, fixture: fixture, preferences: preferences)
            await model.startPlayback(at: index)
            guard !Task.isCancelled else { return }
            guard model.playback != nil else {
                errorMessage = model.errorMessage ?? "这个视频暂时打不开。"
                return
            }
            if sheetIsUp {
                pending = model
                waitsForSheet = true
            } else {
                PlayerSession.shared.show(model, userInitiated: true)
            }
        }
    }

    /// The 回看 sheet has gone; present what was waiting for it.
    func sheetDidDismiss() {
        sheetIsUp = false
        waitsForSheet = false
        guard let model = pending else { return }
        pending = nil
        PlayerSession.shared.show(model, userInitiated: true)
    }
}

private extension Optional where Wrapped == LiveMatch {
    func asyncOr(_ fallback: () async -> LiveMatch?) async -> LiveMatch? {
        if let self { return self }
        return await fallback()
    }
}

/// 回看: recent match recordings that fans post on Weibo, one row per game.
/// Fetched straight from Weibo on the device (see WeiboClient); nothing is
/// stored or re-hosted.
struct ReplaysScreen: View {
    @ObservedObject private var library = ReplayLibrary.shared
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.groups) { group in
                        NavigationLink {
                            ReplayGroupScreen(group: group)
                        } label: {
                            ReplayGroupRow(group: group)
                        }
                    }
                }
                .scoreboardRow()
            }
            if !library.groups.isEmpty {
                Section {
                    EmptyView()
                } footer: {
                    Text("录像来自微博网友上传，打开时现取播放地址。上传的人删了视频，这里也就看不了了。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scoreboardList()
        .overlay {
            if library.groups.isEmpty {
                if library.isLoading {
                    ProgressView("正在找录像…")
                } else if let error = library.errorMessage {
                    ContentUnavailableView {
                        Label("没拿到录像", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("重试") { Task { await library.refresh() } }
                    }
                } else {
                    ContentUnavailableView("最近没有录像", systemImage: "play.rectangle.on.rectangle",
                                           description: Text("比赛结束后一两个小时，网友才会陆续上传。"))
                }
            }
        }
        .refreshable { await library.refresh() }
        .navigationTitle("回看")
        .navigationBarTitleDisplayMode(.inline)
        .task { await library.refreshIfStale() }
        #if DEBUG
        .onChange(of: library.groups) { old, groups in
            if DebugRoute.raw == "replays:play", old.isEmpty, let group = groups.first {
                ReplayLauncher.shared.play(group.videos, at: 0, fixture: nil, preferences: preferences)
            }
        }
        #endif
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

private struct ReplayGroupRow: View {
    let group: ReplayGroup

    var body: some View {
        HStack(spacing: 12) {
            ReplayCover(url: group.videos.first?.coverURL)
                .frame(width: 96, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title).font(.body.weight(.semibold)).lineLimit(1)
                Text(group.partsSummary)
                    .font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Every upload of one game: whole game first, then halves and quarters.
struct ReplayGroupScreen: View {
    let group: ReplayGroup
    @ObservedObject private var launcher = ReplayLauncher.shared
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        List {
            if let error = launcher.errorMessage {
                Section { TouchNotice(message: error, tone: .error) }.scoreboardRow()
            }
            Section {
                ForEach(Array(group.videos.enumerated()), id: \.element.id) { index, video in
                    Button {
                        launcher.play(group.videos, at: index, fixture: nil, preferences: preferences)
                    } label: {
                        ReplayVideoRow(video: video, isOpening: launcher.openingID == video.id)
                    }
                    .tint(.primary)
                    .disabled(launcher.openingID != nil)
                }
            } footer: {
                Text("同一场比赛常有好几个人上传，挑一个能播的就行。播放时可以在顶部换成其他视频；看到一半退出，下次从原处接着播。")
            }
            .scoreboardRow()
        }
        .listStyle(.insetGrouped)
        .scoreboardList()
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { launcher.errorMessage = nil }
    }
}

struct ReplayVideoRow: View {
    let video: ReplayVideo
    var isOpening = false

    var body: some View {
        HStack(spacing: 12) {
            ReplayCover(url: video.coverURL)
                .frame(width: 96, height: 54)
                .overlay(alignment: .bottomTrailing) {
                    Text(ReplayVideo.durationText(video.duration))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .padding(3)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(video.part.label).font(.body.weight(.semibold))
                Text(video.title).font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(2)
                Text(detailText)
                    .font(.caption2).foregroundStyle(Palette.tertiaryText).lineLimit(1)
            }
            Spacer(minLength: 0)
            if isOpening {
                ProgressView()
            } else {
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Palette.accent)
            }
        }
        .padding(.vertical, 2)
    }
}

extension ReplayVideoRow {
    /// "花查章 · 11月26日 10:05 · 看到 1:02:11"
    var detailText: String {
        var parts = [video.author, video.postedAt.formatted(date: .abbreviated, time: .shortened)]
        if let resume = ReplayResume.position(for: video.id) { parts.append("看到 \(ReplayVideo.durationText(resume))") }
        return parts.joined(separator: " · ")
    }
}

struct ReplayCover: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Palette.surface.overlay(Image(systemName: "play.rectangle").foregroundStyle(Palette.tertiaryText))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 回放 on a match screen, once the match is over: a Weibo search for this
/// fixture, checked against both teams and the kickoff date.
struct MatchReplaySection: View {
    @StateObject private var replays: MatchReplays
    @ObservedObject private var launcher = ReplayLauncher.shared
    @EnvironmentObject private var preferences: Preferences
    @State private var showsAll = false

    init(match: LiveMatch) {
        _replays = StateObject(wrappedValue: MatchReplays(match: match))
    }

    var body: some View {
        if MatchReplays.isEligible(replays.match) {
            VStack(alignment: .leading, spacing: 10) {
                Text("回放").font(.headline)
                switch replays.state {
                case .idle, .loading:
                    HStack(spacing: 10) { ProgressView(); Text("正在找录像…").font(.subheadline) }
                case .failed(let message):
                    HStack {
                        Text(message).font(.subheadline).foregroundStyle(Palette.secondaryText)
                        Spacer()
                        Button("重试") { Task { await replays.load() } }
                    }
                case .loaded where replays.videos.isEmpty:
                    Text("还没有人上传这场的录像，过一两个小时再来看看。")
                        .font(.subheadline).foregroundStyle(Palette.secondaryText)
                case .loaded:
                    let shown = showsAll ? replays.videos : Array(replays.videos.prefix(4))
                    if let error = launcher.errorMessage { TouchNotice(message: error, tone: .error) }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, video in
                        Button {
                            // The match itself is the fixture: it orders the teams and feeds 数据.
                            launcher.play(replays.videos, at: index, fixture: replays.match, preferences: preferences)
                        } label: {
                            ReplayVideoRow(video: video, isOpening: launcher.openingID == video.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(launcher.openingID != nil)
                    }
                    if replays.videos.count > shown.count {
                        Button("全部 \(replays.videos.count) 个视频") { showsAll = true }.font(.subheadline)
                    }
                }
            }
            .padding(16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: TouchMetrics.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TouchMetrics.corner, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .task { if replays.state == .idle { await replays.load() } }
        }
    }
}
