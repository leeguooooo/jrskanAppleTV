import AVFoundation
import AVKit
import SwiftUI

/// Presents `AVPlayerViewController` modally from the enclosing screen's own
/// view controller.
///
/// The modal part is load-bearing. Embedded as a child controller — inside a
/// `fullScreenCover`, say — it eats the Menu button without acting on it:
/// SwiftUI's `onExitCommand` never fires, a press gesture recogniser on its view
/// never fires, and Menu falls through to the system, which quits the app
/// instead of going back. Presented properly, tvOS gives Menu its standard
/// dismissal behaviour and reports it through the delegate.
struct PlayerPresenter: UIViewControllerRepresentable {
    @Binding var request: PlaybackRequest?
    let match: LiveMatch
    let channels: [MatchSource]
    let onSelectChannel: (Int) -> Void
    let onStall: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelectChannel = onSelectChannel
        coordinator.onStall = onStall
        coordinator.onDismiss = { request = nil }

        guard let request else {
            coordinator.dismissIfPresenting(from: host)
            return
        }

        coordinator.show(
            request,
            from: host,
            metadata: metadataItems(for: request),
            menuItems: menuItems(currentIndex: request.index)
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Player furniture

    /// Channel switching lives in the transport bar so the viewer never has to
    /// back out to the detail screen mid-match.
    private func menuItems(currentIndex: Int) -> [UIMenuElement] {
        guard channels.count > 1 else { return [] }

        let actions = channels.enumerated().map { index, source -> UIAction in
            let action = UIAction(title: source.name) { _ in
                guard index != currentIndex else { return }
                onSelectChannel(index)
            }
            action.state = index == currentIndex ? .on : .off
            return action
        }

        return [UIMenu(title: "切换线路", options: .displayInline, children: actions)]
    }

    /// Populates the tvOS Info panel. Without this the panel shows the bare
    /// stream URL, which is the clearest tell of an unfinished player.
    private func metadataItems(for request: PlaybackRequest) -> [AVMetadataItem] {
        [
            metadataItem(.commonIdentifierTitle,
                         value: "\(match.homeTeam) vs \(match.awayTeam)"),
            metadataItem(.iTunesMetadataTrackSubTitle,
                         value: "\(match.league) · \(request.sourceName)"),
            metadataItem(.commonIdentifierDescription,
                         value: "\(match.time) 开赛 · 共 \(channels.count) 条线路")
        ].compactMap { $0 }
    }

    private func metadataItem(_ identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem? {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.extendedLanguageTag = "und"
        return item.copy() as? AVMetadataItem
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var onSelectChannel: (Int) -> Void = { _ in }
        var onStall: (String) -> Void = { _ in }
        var onDismiss: () -> Void = {}

        private weak var controller: AVPlayerViewController?
        private var shownRequestID: UUID?
        private var stallWatchdog: Task<Void, Never>?

        func show(
            _ request: PlaybackRequest,
            from host: UIViewController,
            metadata: [AVMetadataItem],
            menuItems: [UIMenuElement]
        ) {
            guard shownRequestID != request.id else {
                controller?.transportBarCustomMenuItems = menuItems
                return
            }
            shownRequestID = request.id

            let item = AVPlayerItem(url: request.url)
            item.externalMetadata = metadata
            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = true

            if let controller {
                // Already on screen — a transport-bar channel switch. Swap the
                // item in place instead of dismissing and re-presenting.
                controller.player = player
                controller.transportBarCustomMenuItems = menuItems
                player.play()
                startStallWatchdog(for: player)
                return
            }

            let controller = AVPlayerViewController()
            controller.player = player
            controller.playbackControlsIncludeInfoViews = true
            controller.transportBarCustomMenuItems = menuItems
            controller.delegate = self
            PlayerWatermark.install(on: controller)
            self.controller = controller

            host.present(controller, animated: true) {
                player.play()
                self.startStallWatchdog(for: player)
            }
        }

        func dismissIfPresenting(from host: UIViewController) {
            stallWatchdog?.cancel()
            stallWatchdog = nil
            shownRequestID = nil

            guard let controller, controller.presentingViewController != nil else {
                self.controller = nil
                return
            }
            controller.player?.pause()
            controller.player = nil
            self.controller = nil
            host.dismiss(animated: true)
        }

        /// A resolved URL is not a working stream. These links go stale
        /// constantly — the match ends, the host rotates — and `AVPlayer`
        /// reports that by simply buffering forever. Without this the viewer
        /// stares at a spinner with no error and no way to another channel.
        private func startStallWatchdog(for player: AVPlayer) {
            stallWatchdog?.cancel()
            stallWatchdog = Task { @MainActor [weak self, weak player] in
                let seconds = 20
                for _ in 0..<(seconds * 2) {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled { return }
                    guard let player, self?.controller?.player === player else { return }

                    if player.currentItem?.status == .failed {
                        self?.reportStall(
                            player.currentItem?.error?.localizedDescription
                                ?? "线路返回的地址无法播放。"
                        )
                        return
                    }
                    if player.timeControlStatus == .playing { return }
                }
                self?.reportStall("线路连上了，但 20 秒内没有画面，多半已经失效。换一条试试。")
            }
        }

        @MainActor
        private func reportStall(_ message: String) {
            onStall(message)
            onDismiss()
        }

        func playerViewControllerDidEndDismissalTransition(
            _ playerViewController: AVPlayerViewController
        ) {
            stallWatchdog?.cancel()
            stallWatchdog = nil
            playerViewController.player?.pause()
            playerViewController.player = nil
            controller = nil
            shownRequestID = nil
            onDismiss()
        }
    }
}
