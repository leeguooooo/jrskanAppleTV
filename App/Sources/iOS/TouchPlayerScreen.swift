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
/// A match is a landscape picture. On a phone-shaped screen the player forces
/// landscape while it is up and releases it when it closes, so the video
/// fills the phone instead of sitting in a strip across a portrait screen.
/// The open iPhone Duo is left in whatever shape the viewer holds it.
struct TouchPlayerScreen: View {
    @ObservedObject var session: PlayerSession
    @ObservedObject var model: MatchPlaybackModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showsStatistics = false
    @State private var visibleNotice: String?

    var body: some View {
        stage
        .task(id: model.notice) {
            visibleNotice = model.notice
            guard visibleNotice != nil else { return }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            visibleNotice = nil
        }
        .sheet(isPresented: $showsStatistics) { SportsStatsSheet(model: model.insights) }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear { Orientation.enterLandscape() }
        .onChange(of: horizontalSizeClass) { _, _ in Orientation.fitPlayer() }
        .onChange(of: verticalSizeClass) { _, _ in Orientation.fitPlayer() }
        #if DEBUG
        // `-close-player <seconds>` closes the player on its own, to check the
        // screen it returns to without synthesising a tap.
        .task {
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: "-close-player"), index + 1 < args.count,
                  let seconds = Double(args[index + 1]) else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            session.isPresented = false
        }
        #endif
        .onDisappear {
            Orientation.restoreDefault()
            if !showsStatistics { session.screenDidDisappear() }
        }
    }

    /// Normally the controls float over the picture. On a half-folded iPhone
    /// Duo the overlay arrangement puts the picture on one half and the
    /// controls on the other, clear of the fold, and that half has room for
    /// the match statistics as well.
    /// Mac Catalyst has no fold and no ArrangementView.
    @ViewBuilder
    private var stage: some View {
        #if targetEnvironment(macCatalyst)
        floatingStage
        #else
        if #available(iOS 27.1, *) {
            GeometryReader { proxy in
                let folded = proxy.reservedRegions(kind: .division).contains { $0.isActive }
                ArrangementView {
                    controls(showsStatistics: folded)
                } secondary: {
                    picture
                }
                .arrangementViewStyle(.overlay)
            }
            .background(Color.black.ignoresSafeArea())
        } else {
            floatingStage
        }
        #endif
    }

    private var floatingStage: some View {
        ZStack(alignment: .top) {
            picture
            controls(showsStatistics: false)
        }
    }

    private var picture: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerContainer(controller: session.controller)
                .ignoresSafeArea()
            SportsDanmakuOverlay(model: model.insights).ignoresSafeArea()
        }
    }

    /// Only the controls themselves take touches; the empty space around them
    /// passes through to the player's own controls.
    private func controls(showsStatistics: Bool) -> some View {
        VStack(spacing: 8) {
            overlay
            if let notice = visibleNotice {
                Text(notice).font(.caption).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.6), in: Capsule())
            }
            if model.resolvingIndex != nil {
                Label("正在恢复播放…", systemImage: "arrow.clockwise")
                    .font(.footnote).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.6), in: Capsule())
            }
            if showsStatistics {
                ScrollView {
                    SportsStatsContent(model: model.insights)
                        .padding(16)
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

            PlayerInsightsControls(model: model.insights, showsStatistics: $showsStatistics)
            RecordControl(model: model)

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

private struct PlayerInsightsControls: View {
    @ObservedObject var model: MatchInsightsModel
    @Binding var showsStatistics: Bool
    var body: some View {
        HStack(spacing: 8) {
            if model.mid != nil {
                Button { model.danmakuEnabled.toggle() } label: {
                    Image(systemName: model.danmakuEnabled ? "captions.bubble.fill" : "captions.bubble")
                        .padding(8).background(.black.opacity(0.45), in: Circle())
                }.accessibilityLabel(model.danmakuEnabled ? "关闭弹幕" : "开启弹幕")
            }
            Button { showsStatistics = true } label: {
                Label("数据", systemImage: "chart.bar.xaxis")
                    .font(.footnote).padding(8).background(.black.opacity(0.45), in: Capsule())
            }
        }
    }
}
