import AVFoundation
import AVKit
import SwiftUI

/// Full-screen live player.
///
/// This is presented as a `fullScreenCover`, not pushed onto the navigation
/// stack — a pushed `VideoPlayer` keeps the navigation bar and safe-area
/// insets, so the picture never actually fills the TV. It wraps
/// `AVPlayerViewController` rather than SwiftUI's `VideoPlayer` to get the
/// native tvOS transport bar, the Info panel, and a custom transport-bar menu
/// for switching channel without leaving playback.
struct PlayerScreen: View {
    let match: LiveMatch
    let channels: [MatchSource]

    @State private var currentIndex: Int
    @State private var player: AVPlayer?
    @State private var phase: Phase = .resolving
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    private let resolver = StreamResolver()

    init(match: LiveMatch, channels: [MatchSource], startAt index: Int) {
        self.match = match
        self.channels = channels
        _currentIndex = State(initialValue: index)
    }

    private enum Phase {
        case resolving
        case playing
        case failed
    }

    private var currentSource: MatchSource? {
        channels.indices.contains(currentIndex) ? channels[currentIndex] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch phase {
            case .playing:
                if let player {
                    SystemPlayerView(player: player, menuItems: channelMenuItems)
                        .ignoresSafeArea()
                }
            case .resolving:
                resolvingOverlay
            case .failed:
                failureOverlay
            }
        }
        .task(id: currentIndex) { await load() }
        .onExitCommand { dismiss() }
        .onDisappear { teardown() }
    }

    // MARK: - Overlays

    private var resolvingOverlay: some View {
        VStack(spacing: 26) {
            ProgressView()
                .controlSize(.large)
                .tint(Palette.accent)

            VStack(spacing: 10) {
                Text("\(match.homeTeam) vs \(match.awayTeam)")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)

                Text("正在解析\(currentSource.map { " \($0.name)" } ?? "线路")…")
                    .font(.body)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
    }

    private var failureOverlay: some View {
        StatusState(
            systemImage: "exclamationmark.triangle",
            title: "这条线路播不了",
            message: errorMessage ?? "线路可能已经失效，换一条再试。",
            actionTitle: "重试",
            action: { Task { await load() } }
        )
        .overlay(alignment: .bottom) {
            if channels.count > 1 {
                HStack(spacing: 16) {
                    ForEach(Array(channels.enumerated()), id: \.element.id) { index, source in
                        Button(source.name) { currentIndex = index }
                            .disabled(index == currentIndex)
                    }
                }
                .padding(.bottom, 60)
            }
        }
    }

    // MARK: - Transport bar menu

    /// Channel switching lives in the transport bar so the viewer never has to
    /// back out to the detail screen mid-match.
    private var channelMenuItems: [UIMenuElement] {
        guard channels.count > 1 else { return [] }

        let actions = channels.enumerated().map { index, source in
            let action = UIAction(title: source.name) { _ in
                Task { @MainActor in
                    guard index != currentIndex else { return }
                    currentIndex = index
                }
            }
            action.state = index == currentIndex ? .on : .off
            return action
        }

        return [UIMenu(title: "切换线路", options: .displayInline, children: actions)]
    }

    // MARK: - Playback

    @MainActor
    private func load() async {
        guard let source = currentSource else {
            phase = .failed
            errorMessage = "这场比赛没有可用线路。"
            return
        }

        teardown()
        phase = .resolving
        errorMessage = nil

        do {
            let streamURL = try await resolver.resolve(sourcePageURL: source.pageURL)
            let item = AVPlayerItem(url: streamURL)
            item.externalMetadata = metadataItems(for: source)

            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.allowsExternalPlayback = true
            player = newPlayer
            phase = .playing
            newPlayer.play()

            await watchForStall(newPlayer)
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
        }
    }

    /// A resolved URL is not a working stream. These links go stale constantly —
    /// the match ends, the host rotates — and `AVPlayer` reports that by simply
    /// buffering forever. Without this watchdog the viewer stares at a spinner
    /// with no error and no way to reach another channel.
    @MainActor
    private func watchForStall(_ player: AVPlayer) async {
        let deadline = 20
        for _ in 0..<(deadline * 2) {
            try? await Task.sleep(nanoseconds: 500_000_000)

            // The task is cancelled and restarted whenever the channel changes.
            if Task.isCancelled { return }
            guard self.player === player else { return }

            if player.currentItem?.status == .failed {
                errorMessage = player.currentItem?.error?.localizedDescription
                    ?? "线路返回的地址无法播放。"
                phase = .failed
                return
            }

            if player.timeControlStatus == .playing { return }
        }

        errorMessage = "线路连上了，但 \(deadline) 秒内没有画面，多半已经失效。换一条试试。"
        phase = .failed
    }

    private func teardown() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    /// Populates the tvOS Info panel. Without this the panel shows the bare
    /// stream URL, which is the clearest tell of an unfinished player.
    private func metadataItems(for source: MatchSource) -> [AVMetadataItem] {
        [
            metadataItem(.commonIdentifierTitle, value: "\(match.homeTeam) vs \(match.awayTeam)"),
            metadataItem(.iTunesMetadataTrackSubTitle, value: "\(match.league) · \(source.name)"),
            metadataItem(.commonIdentifierDescription, value: "\(match.time) 开赛 · 共 \(channels.count) 条线路")
        ].compactMap { $0 }
    }

    private func metadataItem(_ identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem? {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item.copy() as? AVMetadataItem
    }
}

// MARK: - AVPlayerViewController bridge

/// Thin bridge to `AVPlayerViewController`. Everything the tvOS player is good
/// at — scrubbing preview, LIVE indicator, audio/subtitle menus, Info tab —
/// comes free once the controller is used directly.
/// Thin bridge to `AVPlayerViewController`. Everything the tvOS player is good
/// at — scrubbing preview, LIVE indicator, audio and subtitle menus, the Info
/// panel — comes free once the controller is used directly instead of SwiftUI's
/// `VideoPlayer`.
///
/// Presenting this modally instead of embedding it was tried and reverted: it
/// left playback stuck buffering indefinitely on streams that start within
/// seconds when the controller is a plain child.
private struct SystemPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let menuItems: [UIMenuElement]

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.playbackControlsIncludeInfoViews = true
        controller.transportBarCustomMenuItems = menuItems
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        controller.transportBarCustomMenuItems = menuItems
    }
}
