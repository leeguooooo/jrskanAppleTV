import AVFoundation
import AVKit
import SwiftUI

/// Full-screen player for the phone. `AVPlayerViewController` supplies the
/// native controls, Picture in Picture and AirPlay; a thin overlay adds the
/// close button and channel switching, which the iOS controller has no slot
/// for (unlike the tvOS transport bar). A channel switch from the overlay
/// swaps the player item in place instead of re-presenting the cover.
struct PhonePlayerScreen: View {
    @ObservedObject var model: MatchPlaybackModel
    @State private var player = AVPlayer()
    @State private var watchdog: Task<Void, Never>?
    @State private var shownRequestID: UUID?

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            PlayerContainer(player: player)
                .ignoresSafeArea()

            overlay
        }
        .statusBarHidden(true)
        .onAppear { load(model.playback) }
        .onChange(of: model.playback?.id) { _, _ in load(model.playback) }
        .onDisappear {
            watchdog?.cancel()
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    private var overlay: some View {
        HStack(spacing: 12) {
            Button {
                model.stopPlayback()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel("关闭播放")

            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.match.homeTeam) vs \(model.match.awayTeam)")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text("\(model.match.league) · \(model.playback?.sourceName ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .shadow(color: .black.opacity(0.7), radius: 4)

            Spacer()

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
                    Label("线路", systemImage: "list.bullet")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
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

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
