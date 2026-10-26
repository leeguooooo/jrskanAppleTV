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
    @ObservedObject var insights: MatchInsightsModel
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
        coordinator.insights = insights

        guard let request else {
            coordinator.dismissIfPresenting(from: host)
            return
        }

        coordinator.show(
            request,
            from: host,
            metadata: metadataItems(for: request),
            menuItems: menuItems(currentIndex: request.index, statsPresenter: { coordinator.presentStatistics() })
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Player furniture

    /// Channel switching lives in the transport bar so the viewer never has to
    /// back out to the detail screen mid-match.
    private func menuItems(currentIndex: Int, statsPresenter: (() -> Void)?) -> [UIMenuElement] {


        let actions = channels.enumerated().map { index, source -> UIAction in
            let action = UIAction(title: source.name) { _ in
                guard index != currentIndex else { return }
                onSelectChannel(index)
            }
            action.state = index == currentIndex ? .on : .off
            return action
        }

        let toggle = UIAction(title: insights.danmakuEnabled ? "关闭弹幕" : "开启弹幕",
                              image: UIImage(systemName: "captions.bubble")) { _ in
            insights.danmakuEnabled.toggle()
        }
        let stats = UIAction(title: "比赛数据", image: UIImage(systemName: "chart.bar.xaxis")) { _ in
            // Present on the active native player, preserving tvOS Menu handling.
            statsPresenter?()
        }
        var items: [UIMenuElement] = channels.count > 1
            ? [UIMenu(title: "切换线路", options: .displayInline, children: actions)] : []
        if insights.mid != nil { items.append(toggle) }
        items.append(stats)
        return items
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

        var insights: MatchInsightsModel?
        private var commentsHost: UIHostingController<SportsDanmakuOverlay>?

        func presentStatistics() {
            guard let insights, let controller, controller.presentedViewController == nil else { return }
            let panel = UIHostingController(rootView: SportsStatsSheet(model: insights))
            controller.present(panel, animated: true)
        }

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

            if let current = controller, current.presentingViewController == nil || current.isBeingDismissed {
                // Off screen or on its way out (Menu pressed a moment ago, or
                // a presentation that never landed). Swapping the new stream
                // into it would play it where nobody can see it, and the play
                // button would look dead; present a fresh player instead.
                current.player?.pause()
                current.player = nil
                controller = nil
            }

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
            if let insights, let overlay = controller.contentOverlayView {
                let host = UIHostingController(rootView: SportsDanmakuOverlay(model: insights))
                controller.addChild(host)
                host.view.backgroundColor = .clear
                host.view.isUserInteractionEnabled = false
                host.view.translatesAutoresizingMaskIntoConstraints = false
                overlay.addSubview(host.view)
                NSLayoutConstraint.activate([
                    host.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                    host.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                    host.view.topAnchor.constraint(equalTo: overlay.topAnchor),
                    host.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor)
                ])
                host.didMove(toParent: controller)
                commentsHost = host
            }
            self.controller = controller

            let present = {
                host.present(controller, animated: true) {
                    player.play()
                    self.startStallWatchdog(for: player, requestID: request.id)
                }
            }
            // A present asked for while the last player is still animating
            // away is dropped by UIKit; wait for that to finish.
            if let transition = host.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { _ in present() }
            } else {
                present()
            }
        }

        func dismissIfPresenting(from host: UIViewController) {
            endObserver.stop()
            stallWatchdog?.cancel()
            stallWatchdog = nil
            shownRequestID = nil
            commentsHost = nil

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
            playerViewController.player?.pause()
            playerViewController.player = nil
            // A newer player already replaced this one; ending playback now
            // would close it.
            guard playerViewController === controller else { return }
            endObserver.stop()
            stallWatchdog?.cancel()
            stallWatchdog = nil
            playerViewController.player?.pause()
            playerViewController.player = nil
            controller = nil
            shownRequestID = nil
            commentsHost = nil
            onDismiss()
        }
    }
}
