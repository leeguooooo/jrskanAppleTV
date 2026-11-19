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
    /// How much of the picture is held back, 0 (full) to `maxDimming`: a black
    /// layer over the video, under AVKit's controls, so the match is less
    /// eye-catching on a work screen without touching the display brightness.
    /// Kept across launches. Sound is left alone.
    @Published var dimming: Double {
        didSet {
            // Reassigning inside didSet does not call didSet again.
            let clamped = min(Self.maxDimming, max(0, dimming))
            if clamped != dimming { dimming = clamped }
            UserDefaults.standard.set(dimming, forKey: Self.dimmingKey)
            applyDimming()
        }
    }
    /// The picture blacked out completely (the stream and sound keep going).
    @Published var isCovered = false {
        didSet { applyDimming() }
    }
    static let maxDimming = 0.85
    private static let dimmingKey = "playerDimming"
    /// Lives in `contentOverlayView`, above the watermark.
    private let dimView = UIView()

    let player = AVPlayer()
    /// Reused for the whole session so Picture in Picture survives the screen
    /// closing; a controller recreated per screen would end it.
    let controller = AVPlayerViewController()

    private(set) var isPictureInPictureActive = false
    /// The player screen is in the window, which lags `isPresented` by the
    /// length of the cover's animation.
    private var screenIsUp = false
    private var presentsWhenGone = false
    /// AVKit's restore callback, held until the screen it restores into is
    /// in the window. Answered at once, AVKit animated the picture back into
    /// a controller that was not on screen yet and paused the stream.
    private var pendingRestore: ((Bool) -> Void)?
    private var resumesAfterPictureInPicture = false
    private var watchdog: Task<Void, Never>?
    private var shownRequestID: UUID?
    private var playbackObservation: AnyCancellable?
    private let endObserver = PlaybackEndObserver()

    override private init() {
        dimming = min(Self.maxDimming, max(0, UserDefaults.standard.double(forKey: Self.dimmingKey)))
        super.init()
        player.allowsExternalPlayback = true
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        #if targetEnvironment(macCatalyst)
        // The Mac's menu-bar 正在播放 would show both teams to anyone glancing at it.
        controller.updatesNowPlayingInfoCenter = false
        #else
        controller.updatesNowPlayingInfoCenter = true
        #endif
        controller.videoGravity = .resizeAspect
        controller.delegate = self
        PlayerWatermark.install(on: controller)
        installDimView()
    }

    private func installDimView() {
        guard let overlay = controller.contentOverlayView else { return }
        dimView.backgroundColor = .black
        dimView.isUserInteractionEnabled = false
        dimView.isAccessibilityElement = false
        dimView.frame = overlay.bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.addSubview(dimView)
        applyDimming()
    }

    private func applyDimming() {
        dimView.alpha = isCovered ? 1 : dimming
    }

    /// What is left of the picture, for layers drawn over it (danmaku).
    var pictureVisibility: Double { isCovered ? 0 : 1 - dimming }

    /// One step darker or brighter, for the menu and keyboard shortcuts.
    func adjustDimming(by step: Double) {
        isCovered = false
        dimming = ((dimming + step) * 100).rounded() / 100
    }

    /// Called when a match screen's model has a resolved stream to show.
    /// `userInitiated` is the viewer tapping 继续观看: that always brings the
    /// screen back, floating window or not; only automatic switches stay out.
    func show(_ model: MatchPlaybackModel, userInitiated: Bool = false) {
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
        } else if isPictureInPictureActive && !isPresented && !userInitiated {
            // An automatic channel switch inside the floating window must
            // not throw the full-screen player back over the match list.
            return
        }
        if screenIsUp && !isPresented {
            // The last screen is still animating away. A cover asked for now
            // is dropped, and its disappearance would then end this stream;
            // present once it has gone instead.
            presentsWhenGone = true
            return
        }
        isPresented = true
        if userInitiated && isPictureInPictureActive {
            // Take the picture back from the floating window; left floating,
            // the screen would open on AVKit's empty placeholder.
            controller.allowsPictureInPicturePlayback = false
            controller.allowsPictureInPicturePlayback = true
        }
    }

    func screenDidAppear() {
        screenIsUp = true
        guard let restore = pendingRestore else { return }
        pendingRestore = nil
        // Let the host adopt the controller first.
        Task { @MainActor in restore(true) }
    }

    /// The player screen left the window. Without Picture in Picture that is
    /// the viewer closing it; with it, the floating window keeps playing.
    func screenDidDisappear() {
        screenIsUp = false
        if presentsWhenGone {
            presentsWhenGone = false
            Task { @MainActor in self.isPresented = self.model != nil }
            return
        }
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
        pendingRestore?(false)
        pendingRestore = nil
        resumesAfterPictureInPicture = false
        model?.stopPlayback()
        model = nil
        presentsWhenGone = false
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
        #if !targetEnvironment(macCatalyst)
        item.externalMetadata = metadataItems(for: request, match: model.match)
        #endif
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
                    itemFailed: player.currentItem?.status == .failed,
                    buffered: player.currentItem?.loadedTimeRanges.last.map { CMTimeRangeGetEnd($0.timeRangeValue).seconds })
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

    /// Will-start already set the flag. Left set, closing the screen would
    /// keep the stream playing unseen and 继续观看 would do nothing.
    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        MainActor.assumeIsolated {
            isPictureInPictureActive = false
            if !isPresented { end() }
        }
    }

    nonisolated func playerViewControllerWillStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        MainActor.assumeIsolated { resumesAfterPictureInPicture = player.timeControlStatus != .paused }
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        MainActor.assumeIsolated {
            isPictureInPictureActive = false
            // Closed from the floating window with no screen behind it.
            if !isPresented && !presentsWhenGone { end(); return }
            // Coming back to the app hands the picture back; AVKit can leave
            // it paused on the way, and a live match should just carry on.
            if resumesAfterPictureInPicture && model?.playback != nil { player.play() }
            resumesAfterPictureInPicture = false
        }
    }

    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated {
            guard model != nil else { return completionHandler(false) }
            if screenIsUp && isPresented { return completionHandler(true) }
            pendingRestore?(false)
            pendingRestore = completionHandler
            if screenIsUp { presentsWhenGone = true } else { isPresented = true }
            // Never leave AVKit waiting if the screen does not come up.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, let restore = self.pendingRestore else { return }
                self.pendingRestore = nil
                restore(self.screenIsUp)
            }
        }
    }
}
