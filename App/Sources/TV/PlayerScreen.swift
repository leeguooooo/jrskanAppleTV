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
    let onStall: (UUID, String) -> Void
    let onConfirmed: (UUID, TimeInterval) -> Void
    let onStop: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelectChannel = onSelectChannel
        coordinator.onStall = onStall
        coordinator.onConfirmed = onConfirmed
        coordinator.onDismiss = onStop

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
        var onStall: (UUID, String) -> Void = { _, _ in }
        var onConfirmed: (UUID, TimeInterval) -> Void = { _, _ in }
        var onDismiss: () -> Void = {}

        private weak var controller: AVPlayerViewController?
        private var shownRequestID: UUID?
        private var stallWatchdog: Task<Void, Never>?
        private let endObserver = PlaybackEndObserver()

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
                startStallWatchdog(for: player, requestID: request.id)
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
                self.startStallWatchdog(for: player, requestID: request.id)
            }
        }

        func dismissIfPresenting(from host: UIViewController) {
            endObserver.stop()
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

        private func startStallWatchdog(for player: AVPlayer, requestID: UUID) {
            stallWatchdog?.cancel()
            if let item = player.currentItem {
                endObserver.observe(item) { [weak self, weak player] in
                    guard let self, let player, self.controller?.player === player,
                          self.shownRequestID == requestID else { return }
                    self.onStall(requestID, "播放已停止，请重试或切换线路。")
                }
            }
            stallWatchdog = Task { @MainActor [weak self, weak player] in
                var health = PlaybackHealthMonitor(now: ProcessInfo.processInfo.systemUptime)
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled, let self, let player,
                          self.controller?.player === player, self.shownRequestID == requestID else { return }
                    let event = health.sample(now: ProcessInfo.processInfo.systemUptime,
                        mediaTime: player.currentTime().seconds, playing: player.timeControlStatus == .playing,
                        paused: player.timeControlStatus == .paused && player.currentItem?.status != .unknown,
                        ready: self.controller?.isReadyForDisplay == true,
                        itemFailed: player.currentItem?.status == .failed)
                    switch event {
                    case .confirmed(let startup): self.onConfirmed(requestID, startup)
                    case .stalled:
                        self.onStall(requestID, player.currentItem?.error?.localizedDescription
                            ?? (health.confirmed ? "播放中断，暂时无法恢复。" : "20 秒内没有出现画面。"))
                        return
                    case nil: break
                    }
                }
            }
        }

        func playerViewControllerDidEndDismissalTransition(
            _ playerViewController: AVPlayerViewController
        ) {
            endObserver.stop()
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
