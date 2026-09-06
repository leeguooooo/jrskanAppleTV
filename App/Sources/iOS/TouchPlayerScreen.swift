import AVFoundation
import AVKit
import SwiftUI

/// Full-screen player for the phone. `AVPlayerViewController` supplies the
/// native controls, close button, Picture in Picture and AirPlay; a small
/// overlay at the top centre adds what the iOS controller has no slot for:
/// channel switching and an aspect-fill toggle. The overlay stays clear of
/// the controller's own corners (close top-left, PiP and AirPlay top-right).
///
/// A match is a landscape picture. The screen is forced into landscape while
/// the player is up and released when it closes, so the video fills the phone
/// instead of sitting in a strip across a portrait screen.
struct TouchPlayerScreen: View {
    @ObservedObject var model: MatchPlaybackModel
    @State private var player = AVPlayer()
    @State private var watchdog: Task<Void, Never>?
    @State private var shownRequestID: UUID?
    @State private var fillsScreen = false
    @StateObject private var displayState = PlaybackDisplayState()
    @StateObject private var endObserver = PlaybackEndObserver()

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            PlayerContainer(player: player, gravity: fillsScreen ? .resizeAspectFill : .resizeAspect,
                            displayState: displayState)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                overlay
                if model.resolvingIndex != nil {
                    Label("正在恢复播放…", systemImage: "arrow.clockwise")
                        .font(.footnote).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.6), in: Capsule())
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            Orientation.enterLandscape()
            load(model.playback)
        }
        .onChange(of: model.playback?.id) { _, _ in load(model.playback) }
        .onDisappear {
            watchdog?.cancel()
            endObserver.stop()
            player.pause()
            player.replaceCurrentItem(with: nil)
            Orientation.restoreDefault()
            model.stopPlayback()
        }
    }

    private var overlay: some View {
        HStack(spacing: 8) {
            if model.resolvedChannels.count > 1 {
                Menu {
                    ForEach(Array(model.resolvedChannels.enumerated()), id: \.element.id) { index, source in
                        Button {
                            guard index != model.playback?.index else { return }
                            Task { await model.startPlayback(at: index) }
                        } label: {
                            if index == model.playback?.index {
                                Label(source.name, systemImage: "checkmark")
                            } else {
                                Text(source.name)
                            }
                        }
                    }
                } label: {
                    Label(model.playback?.sourceName ?? "线路", systemImage: "list.bullet")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                }
            }

            Button {
                fillsScreen.toggle()
            } label: {
                Image(systemName: fillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.footnote.weight(.semibold))
                    .padding(8)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel(fillsScreen ? "适应屏幕" : "填满屏幕")
        }
        .foregroundStyle(.white)
        .padding(.top, 10)
    }

    private func load(_ request: PlaybackRequest?) {
        guard let request, request.id != shownRequestID else { return }
        shownRequestID = request.id
        let item = AVPlayerItem(url: request.url)
        item.externalMetadata = metadataItems(for: request)
        player.replaceCurrentItem(with: item)
        endObserver.observe(item) { [weak model] in
            model?.handleStall("播放已停止，请重试或切换线路。", requestID: request.id)
        }
        player.allowsExternalPlayback = true
        player.play()
        startWatchdog(requestID: request.id)
    }

    private func startWatchdog(requestID: UUID) {
        watchdog?.cancel()
        watchdog = Task { @MainActor in
            var health = PlaybackHealthMonitor(now: ProcessInfo.processInfo.systemUptime)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, model.playback?.id == requestID else { return }
                let event = health.sample(now: ProcessInfo.processInfo.systemUptime,
                    mediaTime: player.currentTime().seconds, playing: player.timeControlStatus == .playing,
                    paused: player.timeControlStatus == .paused && player.currentItem?.status != .unknown,
                    ready: displayState.controller?.isReadyForDisplay == true,
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

    private func metadataItems(for request: PlaybackRequest) -> [AVMetadataItem] {
        [
            metadataItem(.commonIdentifierTitle, value: "\(model.match.homeTeam) vs \(model.match.awayTeam)"),
            metadataItem(.iTunesMetadataTrackSubTitle, value: "\(model.match.league) · \(request.sourceName)")
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

private final class PlaybackDisplayState: ObservableObject {
    weak var controller: AVPlayerViewController?
}

private struct PlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    let displayState: PlaybackDisplayState

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.videoGravity = gravity
        PlayerWatermark.install(on: controller)
        displayState.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        if controller.videoGravity != gravity { controller.videoGravity = gravity }
    }
}
