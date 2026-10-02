import AVFoundation
import AVKit
import Combine
import SwiftUI

/// The one playing stream, owned above any screen.
///
/// The player used to live inside the full-screen cover, so anything that
/// removed that view — a layout swap on rotation, closing the screen while
/// Picture in Picture was up — tore the stream down with it. Here the player,
/// its controller, the health watchdog and the match model outlive the
/// screen: closing the screen during Picture in Picture leaves the floating
/// window playing (and switching channels if one dies), and the window's
/// restore button brings the screen back.
@MainActor
final class PlayerSession: NSObject, ObservableObject {
    static let shared = PlayerSession()

    /// Drives the root-level full-screen cover.
    @Published var isPresented = false
    @Published private(set) var model: MatchPlaybackModel?
    @Published var fillsScreen = false {
        didSet { controller.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect }
    }

    let player = AVPlayer()
    /// Reused for the whole session so Picture in Picture survives the screen
    /// closing; a controller recreated per screen would end it.
    let controller = AVPlayerViewController()

    private(set) var isPictureInPictureActive = false
    private var watchdog: Task<Void, Never>?
    private var shownRequestID: UUID?
    private var playbackObservation: AnyCancellable?
    private let endObserver = PlaybackEndObserver()

    override private init() {
        super.init()
        player.allowsExternalPlayback = true
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.videoGravity = .resizeAspect
        controller.delegate = self
        PlayerWatermark.install(on: controller)
    }

    /// Called when a match screen's model has a resolved stream to show.
    func show(_ model: MatchPlaybackModel) {
        if self.model !== model {
            end()
            self.model = model
            // Channel switches, automatic fallback and "all channels failed"
            // all arrive as changes to `playback`.
            playbackObservation = model.$playback
                .removeDuplicates { $0?.id == $1?.id }
                .sink { [weak self] request in
                    // @Published emits before the property is set; read the
                    // value it delivers rather than the model.
                    Task { @MainActor in self?.apply(request) }
                }
        } else if isPictureInPictureActive && !isPresented {
            // An automatic channel switch inside the floating window must
            // not throw the full-screen player back over the match list.
            return
        }
        isPresented = true
    }

    /// The player screen left the window. Without Picture in Picture that is
    /// the viewer closing it; with it, the floating window keeps playing.
    func screenDidDisappear() {
        isPresented = false
        if !isPictureInPictureActive { end() }
    }

    /// Stop everything and forget the match.
    func end() {
        watchdog?.cancel()
        watchdog = nil
        endObserver.stop()
        player.pause()
        player.replaceCurrentItem(with: nil)
        shownRequestID = nil
        playbackObservation = nil
        model?.stopPlayback()
        model = nil
        isPresented = false
    }

    private func apply(_ request: PlaybackRequest?) {
        guard let request else {
            // Every channel failed or the model was stopped: the error is on
            // the match screen, so close the player and the floating window.
            if model != nil { end() }
            return
        }
        guard request.id != shownRequestID, let model else { return }
        shownRequestID = request.id
        let item = AVPlayerItem(url: request.url)
        item.externalMetadata = metadataItems(for: request, match: model.match)
        player.replaceCurrentItem(with: item)
        endObserver.observe(item) { [weak model] in
            model?.handleStall("播放已停止，请重试或切换线路。", requestID: request.id)
        }
        player.play()
        startWatchdog(requestID: request.id)
    }

    private func startWatchdog(requestID: UUID) {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            var health = PlaybackHealthMonitor(now: ProcessInfo.processInfo.systemUptime)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, let model = self.model,
                      model.playback?.id == requestID else { return }
                let player = self.player
                let event = health.sample(now: ProcessInfo.processInfo.systemUptime,
                    mediaTime: player.currentTime().seconds, playing: player.timeControlStatus == .playing,
                    paused: player.timeControlStatus == .paused && player.currentItem?.status != .unknown,
                    ready: self.hasPicture,
                    itemFailed: player.currentItem?.status == .failed)
                switch event {
                case .confirmed(let startup):
                    model.confirmPlayback(requestID: requestID, startupSeconds: startup)
                case .stalled:
                    model.handleStall(player.currentItem?.error?.localizedDescription
                        ?? (health.confirmed ? "播放中断，暂时无法恢复。" : "20 秒内没有出现画面。"), requestID: requestID)
                    return
                case nil: break
                }
            }
        }
    }

    /// Whether a picture is reaching the viewer. During AirPlay the frames go
    /// to the TV and the local controller never reports ready for display;
    /// treating that as "no picture" used to fail a perfectly good stream
    /// after 20 seconds and hop channels on the TV.
    private var hasPicture: Bool {
        controller.isReadyForDisplay || player.isExternalPlaybackActive
            || (isPictureInPictureActive && player.currentItem?.status == .readyToPlay)
    }

    private func metadataItems(for request: PlaybackRequest, match: LiveMatch) -> [AVMetadataItem] {
        [
            metadataItem(.commonIdentifierTitle, value: "\(match.homeTeam) vs \(match.awayTeam)"),
            metadataItem(.iTunesMetadataTrackSubTitle, value: "\(match.league) · \(request.sourceName)")
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

extension PlayerSession: AVPlayerViewControllerDelegate {
    nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        MainActor.assumeIsolated { isPictureInPictureActive = true }
    }

    /// AVKit hides the inline controls, close button included, while the
    /// floating window is up, which would strand the viewer on an empty black
    /// screen. Step out of the way the way system apps do: the window keeps
    /// playing over the match list, and its restore button brings this back.
    nonisolated func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        MainActor.assumeIsolated { isPresented = false }
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        MainActor.assumeIsolated {
            isPictureInPictureActive = false
            // Closed from the floating window with no screen behind it.
            if !isPresented { end() }
        }
    }

    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            guard model != nil else { return completionHandler(false) }
            isPresented = true
            completionHandler(true)
        }
    }
}
