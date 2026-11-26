import AVKit
import Combine
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

/// Every upload of one game; picking one plays it.
struct ReplayGroupView: View {
    let group: ReplayGroup
    @State private var playing: ReplayVideo?
    @State private var errorMessage: String?
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
                    if let errorMessage { Text(errorMessage).foregroundStyle(Palette.live) }
                    ForEach(group.videos) { video in
                        Button { errorMessage = nil; playing = video } label: { TVReplayVideoCard(video: video) }
                            .buttonStyle(FocusCardButtonStyle())
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 46)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onExitCommand { dismiss() }
        .background(ReplayPlayerPresenter(video: $playing, onError: { errorMessage = $0 }))
    }
}

struct TVReplayVideoCard: View {
    let video: ReplayVideo

    var body: some View {
        HStack(spacing: 28) {
            TVReplayCover(url: video.coverURL)
                .frame(width: 192, height: 108)
            VStack(alignment: .leading, spacing: 6) {
                Text(video.part.label).font(.title3.weight(.bold)).foregroundStyle(Palette.primaryText)
                Text(video.title).font(.callout).foregroundStyle(Palette.secondaryText).lineLimit(1)
                Text("\(ReplayVideo.durationText(video.duration)) · \(video.author)")
                    .font(.caption.monospacedDigit()).foregroundStyle(Palette.tertiaryText)
            }
            Spacer()
            Image(systemName: "play.fill").foregroundStyle(Palette.accent)
        }
        .padding(18)
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
    @State private var playing: ReplayVideo?
    @State private var errorMessage: String?

    init(match: LiveMatch) {
        _replays = StateObject(wrappedValue: MatchReplays(match: match))
    }

    var body: some View {
        if MatchReplays.isEligible(replays.match) {
            VStack(alignment: .leading, spacing: 18) {
                Text("回放").font(.title3.weight(.bold)).foregroundStyle(Palette.primaryText)
                if let errorMessage { Text(errorMessage).foregroundStyle(Palette.live) }
                switch replays.state {
                case .idle, .loading:
                    HStack(spacing: 16) { ProgressView(); Text("正在找录像…") }
                case .failed(let message):
                    Button { Task { await replays.load() } } label: { Label("\(message) 重试", systemImage: "arrow.clockwise") }
                case .loaded where replays.videos.isEmpty:
                    Text("还没有人上传这场的录像，过一两个小时再来看看。").foregroundStyle(Palette.secondaryText)
                case .loaded:
                    ForEach(replays.videos.prefix(6)) { video in
                        Button { errorMessage = nil; playing = video } label: { TVReplayVideoCard(video: video) }
                            .buttonStyle(FocusCardButtonStyle())
                    }
                }
            }
            .task { if replays.state == .idle { await replays.load() } }
            .background(ReplayPlayerPresenter(video: $playing, onError: { errorMessage = $0 }))
        }
    }
}

/// Presents AVPlayerViewController modally, like PlayerPresenter does for the
/// live stream: embedded, it swallows the Menu button and the app quits.
struct ReplayPlayerPresenter: UIViewControllerRepresentable {
    @Binding var video: ReplayVideo?
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onFinish = { message in
            video = nil
            if let message { onError(message) }
        }
        if let video {
            coordinator.show(video, from: host)
        } else {
            coordinator.dismiss(from: host)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var onFinish: (String?) -> Void = { _ in }
        private weak var controller: AVPlayerViewController?
        private var playback: ReplayPlayback?
        private var subscriptions: Set<AnyCancellable> = []

        func show(_ video: ReplayVideo, from host: UIViewController) {
            guard playback?.video.id != video.id else { return }
            let playback = ReplayPlayback(video: video)
            self.playback = playback
            let controller = AVPlayerViewController()
            controller.delegate = self
            self.controller = controller
            subscriptions = []
            playback.$player.compactMap { $0 }.sink { [weak controller] player in
                if controller?.player !== player { controller?.player = player }
            }.store(in: &subscriptions)
            playback.$errorMessage.compactMap { $0 }.sink { [weak self, weak host] message in
                guard let self, let host else { return }
                self.finish(message: message, host: host)
            }.store(in: &subscriptions)
            host.present(controller, animated: true)
            Task { await playback.start() }
        }

        func dismiss(from host: UIViewController) {
            guard playback != nil else { return }
            finish(message: nil, host: host)
        }

        private func finish(message: String?, host: UIViewController) {
            playback?.stop()
            playback = nil
            subscriptions = []
            if let controller, controller.presentingViewController != nil {
                controller.player = nil
                host.dismiss(animated: true)
            }
            controller = nil
            onFinish(message)
        }

        nonisolated func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
            MainActor.assumeIsolated {
                guard playerViewController === controller else { return }
                playback?.stop()
                playback = nil
                subscriptions = []
                controller = nil
                onFinish(nil)
            }
        }
    }
}
