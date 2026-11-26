import AVKit
import SwiftUI

/// 回看: recent match recordings that fans post on Weibo, one row per game.
/// Fetched straight from Weibo on the device (see WeiboClient); nothing is
/// stored or re-hosted.
struct ReplaysScreen: View {
    @ObservedObject private var library = ReplayLibrary.shared
    @State private var playing: ReplayVideo?

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
        .fullScreenCover(item: $playing) { ReplayPlayerScreen(video: $0) }
        #if DEBUG
        .onChange(of: library.groups) { _, groups in
            if DebugRoute.raw == "replays:play", playing == nil { playing = groups.first?.videos.first }
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
    @State private var playing: ReplayVideo?

    var body: some View {
        List {
            Section {
                ForEach(group.videos) { video in
                    Button { playing = video } label: { ReplayVideoRow(video: video) }
                        .tint(.primary)
                }
            } footer: {
                Text("同一场比赛常有好几个人上传，挑一个能播的就行。")
            }
            .scoreboardRow()
        }
        .listStyle(.insetGrouped)
        .scoreboardList()
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playing) { ReplayPlayerScreen(video: $0) }
    }
}

struct ReplayVideoRow: View {
    let video: ReplayVideo

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
                Text("\(video.author) · \(video.postedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(Palette.tertiaryText).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Palette.accent)
        }
        .padding(.vertical, 2)
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
    @State private var playing: ReplayVideo?
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
                    ForEach(shown) { video in
                        Button { playing = video } label: { ReplayVideoRow(video: video) }
                            .buttonStyle(.plain)
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
            .fullScreenCover(item: $playing) { ReplayPlayerScreen(video: $0) }
        }
    }
}

/// Full-screen player for one recording. Separate from PlayerSession, which
/// belongs to the live stream; no recording control, no channels.
struct ReplayPlayerScreen: View {
    @StateObject private var playback: ReplayPlayback
    @Environment(\.dismiss) private var dismiss

    init(video: ReplayVideo) {
        _playback = StateObject(wrappedValue: ReplayPlayback(video: video))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = playback.player {
                ReplayPlayerContainer(player: player).ignoresSafeArea()
            } else if playback.errorMessage == nil {
                ProgressView().tint(.white)
            }
            // A full-screen cover cannot be swiped away, and the embedded
            // AVPlayerViewController draws no Done button of its own.
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .accessibilityLabel("关闭")
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            if let message = playback.errorMessage {
                VStack(spacing: 12) {
                    Text(message).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("关闭") { dismiss() }.buttonStyle(.borderedProminent)
                }
                .padding(24)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task {
            PlayerSession.shared.player.pause()
            await playback.start()
        }
        #if DEBUG
        // `-close-replay <s>` closes the player that long after it opens.
        .task {
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: "-close-replay"), index + 1 < args.count,
                  let seconds = Double(args[index + 1]) else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            dismiss()
        }
        #endif
        .onAppear { Orientation.enterLandscape() }
        .onDisappear {
            playback.stop()
            Orientation.restoreDefault()
        }
    }
}

private struct ReplayPlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
