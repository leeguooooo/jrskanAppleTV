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
struct PhonePlayerScreen: View {
    @ObservedObject var model: MatchPlaybackModel
    @State private var player = AVPlayer()
    @State private var watchdog: Task<Void, Never>?
    @State private var shownRequestID: UUID?
    @State private var fillsScreen = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            PlayerContainer(player: player, gravity: fillsScreen ? .resizeAspectFill : .resizeAspect)
                .ignoresSafeArea()

            overlay
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
            player.pause()
            player.replaceCurrentItem(with: nil)
            Orientation.restoreDefault()
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
        player.allowsExternalPlayback = true
        player.play()
        startWatchdog()
    }

    /// A resolved URL is not a working stream. These links go stale
    /// constantly — the match ends, the host rotates — and `AVPlayer` reports
    /// that by simply buffering forever. Same 20-second rule as the TV.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                if player.currentItem?.status == .failed {
                    model.handleStall(player.currentItem?.error?.localizedDescription ?? "线路返回的地址无法播放。")
                    return
                }
                if player.timeControlStatus == .playing { return }
            }
            model.handleStall("线路连上了，但 20 秒内没有画面，多半已经失效。换一条试试。")
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

private struct PlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.videoGravity = gravity
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        if controller.videoGravity != gravity { controller.videoGravity = gravity }
    }
}
