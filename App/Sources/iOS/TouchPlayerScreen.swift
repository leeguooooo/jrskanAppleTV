import AVFoundation
import AVKit
import SwiftUI

/// Full-screen player for the phone. `AVPlayerViewController` supplies the
/// native controls, close button, Picture in Picture and AirPlay; a small
/// overlay at the top centre adds what the iOS controller has no slot for:
/// channel switching and an aspect-fill toggle. The overlay stays clear of
/// the controller's own corners (close top-left, PiP and AirPlay top-right).
///
/// The screen only shows the stream; `PlayerSession` owns it, so closing the
/// screen during Picture in Picture keeps the floating window playing.
///
/// A match is a landscape picture. The screen is forced into landscape while
/// the player is up and released when it closes, so the video fills the phone
/// instead of sitting in a strip across a portrait screen.
struct TouchPlayerScreen: View {
    @ObservedObject var session: PlayerSession
    @ObservedObject var model: MatchPlaybackModel

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            PlayerContainer(controller: session.controller)
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
        .onAppear { Orientation.enterLandscape() }
        .onDisappear {
            Orientation.restoreDefault()
            session.screenDidDisappear()
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
                session.fillsScreen.toggle()
            } label: {
                Image(systemName: session.fillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.footnote.weight(.semibold))
                    .padding(8)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel(session.fillsScreen ? "适应屏幕" : "填满屏幕")
        }
        .foregroundStyle(.white)
        .padding(.top, 10)
    }
}

/// Hosts the session's long-lived controller. SwiftUI may tear this wrapper
/// down and rebuild it; the controller, and any Picture in Picture it owns,
/// stays with the session.
private struct PlayerContainer: UIViewControllerRepresentable {
    let controller: AVPlayerViewController

    func makeUIViewController(context: Context) -> AVPlayerViewController { controller }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}
