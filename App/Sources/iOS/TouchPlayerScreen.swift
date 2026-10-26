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
/// On a phone-shaped screen the player follows the phone. Upright, the
/// picture is pinned to the top with the score and match statistics under
/// it; sideways (or after the full-screen button) the picture fills the
/// screen, and 数据 shrinks it to the left with the statistics beside it.
/// Either way the stream keeps playing.
/// The open iPhone Duo is left in whatever shape the viewer holds it.
struct TouchPlayerScreen: View {
    @ObservedObject var session: PlayerSession
    @ObservedObject var model: MatchPlaybackModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @EnvironmentObject private var listModel: MatchListModel
    @State private var showsStatistics = false
    @State private var visibleNotice: String?
    /// The button row over the picture comes and goes with AVKit's own
    /// controls: a tap on the picture toggles it, and it fades after a while.
    @State private var controlsVisible = true
    @State private var controlsTouch = 0

    var body: some View {
        stage
        .task(id: model.notice) {
            visibleNotice = model.notice
            guard visibleNotice != nil else { return }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            visibleNotice = nil
        }
        .statusBarHidden(!isUpright)
        .persistentSystemOverlays(.hidden)
        .task(id: controlsTouch) {
            guard controlsVisible else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
        }
        .onAppear {
            session.screenDidAppear()
            Orientation.enterPlayer()
        }
        .onChange(of: horizontalSizeClass) { _, _ in Orientation.fitPlayer() }
        .onChange(of: verticalSizeClass) { _, _ in Orientation.fitPlayer() }
        // A new layout brings the row back for a moment, the way a tap does.
        .onChange(of: isUpright) { _, upright in
            controlsVisible = true
            controlsTouch += 1
            // The upright box has no 铺满 button to undo a crop with.
            if upright { session.fillsScreen = false }
        }
        #if DEBUG
        // `-close-player <seconds>` closes the player on its own, to check the
        // screen it returns to without synthesising a tap.
        .task {
            let args = CommandLine.arguments
            // `-player-fullscreen` / `-stats-panel` reach the landscape layouts without rotating by hand.
            // Both wait a few seconds so the turn happens mid-stream, like a real one.
            if args.contains("-player-fullscreen") || args.contains("-stats-panel") {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if args.contains("-player-fullscreen") { Orientation.enterFullScreen() }
                if args.contains("-stats-panel") { showsStatistics = true }
            }
            guard let index = args.firstIndex(of: "-close-player"), index + 1 < args.count,
                  let seconds = Double(args[index + 1]) else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            session.isPresented = false
        }
        #endif
        .onDisappear {
            Orientation.restoreDefault()
            session.screenDidDisappear()
        }
    }

    /// Normally the screen follows the phone (see `floatingStage`). On a
    /// half-folded iPhone Duo the overlay arrangement puts the picture on one
    /// half and the controls on the other, clear of the fold, and that half
    /// has room for the match statistics as well.
    /// Mac Catalyst has no fold and no ArrangementView.
    @ViewBuilder
    private var stage: some View {
        #if targetEnvironment(macCatalyst)
        floatingStage
        #else
        if #available(iOS 27.1, *) {
            GeometryReader { proxy in
                if proxy.reservedRegions(kind: .division).contains(where: \.isActive) {
                    ArrangementView {
                        controls(showsStatistics: true)
                    } secondary: {
                        picture
                    }
                    .arrangementViewStyle(.overlay)
                    .background(Color.black.ignoresSafeArea())
                } else {
                    floatingStage
                }
            }
        } else {
            floatingStage
        }
        #endif
    }

    /// A phone on its side: compact tall.
    private var isPhoneSideways: Bool { verticalSizeClass == .compact }

    /// A phone held upright: compact wide, regular tall.
    private var isUpright: Bool {
        horizontalSizeClass == .compact && verticalSizeClass == .regular
    }

    @ViewBuilder
    private var floatingStage: some View {
        if isUpright {
            uprightStage
        } else if showsStatistics {
            HStack(spacing: 0) {
                ZStack(alignment: .top) {
                    picture
                    controls(showsStatistics: false)
                }
                statisticsPanel
                    .frame(width: horizontalSizeClass == .regular ? 420 : 360)
                    .transition(.move(edge: .trailing))
            }
            .background(Palette.backgroundBottom.ignoresSafeArea())
        } else {
            ZStack(alignment: .top) {
                picture
                controls(showsStatistics: false)
            }
        }
    }

    /// Statistics beside the picture; the picture keeps playing, smaller.
    private var statisticsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("比赛数据").font(BrandFont.heading(19, relativeTo: .headline))
                Spacer()
                Button { withAnimation(.snappy) { showsStatistics = false } } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("收起数据")
            }
            .foregroundStyle(Palette.primaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ScrollView {
                SportsStatsContent(model: model.insights)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(TouchBackground())
        .overlay(alignment: .leading) { Rectangle().fill(Palette.hairline).frame(width: 1) }
    }

    /// Upright phone: picture pinned on top, score strip, statistics below.
    private var uprightStage: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color.black
                PlayerContainer(controller: session.controller, onTap: togglePictureControls)
                SportsDanmakuOverlay(model: model.insights)
                controls(showsStatistics: false)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            scoreStrip
            ScrollView {
                SportsStatsContent(model: model.insights, showsScoreboard: false, compactWhenEmpty: true)
                    .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .background(TouchBackground())
    }

    private var currentMatch: LiveMatch {
        listModel.matches.first { $0.id == model.match.id } ?? model.match
    }

    private var scoreStrip: some View {
        let match = currentMatch
        let home = match.scoreText == nil ? nil : match.providerState?.homeScore
        let away = match.scoreText == nil ? nil : match.providerState?.awayScore
        let status = MatchSchedule.status(for: match, now: Date())
        return HStack(spacing: 10) {
            Button { session.isPresented = false } label: {
                Image(systemName: "chevron.down").font(.footnote.weight(.bold))
                    .frame(width: 32, height: 32)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("关闭播放器")
            TeamCrest(url: match.homeLogoURL, teamName: match.homeTeam, size: 28, framed: false)
            Text(match.homeTeam).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            VStack(spacing: 0) {
                if let home, let away {
                    LEDScore(text: "\(home) : \(away)", size: 32)
                } else {
                    Text("VS").font(BrandFont.score(28)).foregroundStyle(Palette.tertiaryText)
                }
                if case .live(let label) = status {
                    Text(label).font(BrandFont.numeric(11, bold: true, relativeTo: .caption2)).foregroundStyle(Palette.live)
                }
            }
            .fixedSize()
            Spacer(minLength: 4)
            Text(match.awayTeam).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            TeamCrest(url: match.awayLogoURL, teamName: match.awayTeam, size: 28, framed: false)
            Button { Orientation.enterFullScreen() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.footnote.weight(.bold))
                    .frame(width: 32, height: 32)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            }
            .accessibilityLabel("横屏全屏")
        }
        .foregroundStyle(Palette.primaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Palette.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    private var picture: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerContainer(controller: session.controller, onTap: togglePictureControls)
                .ignoresSafeArea(edges: showsStatistics ? [.vertical, .leading] : .all)
            SportsDanmakuOverlay(model: model.insights).ignoresSafeArea()
        }
    }

    private func togglePictureControls() {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible.toggle() }
        controlsTouch += 1
    }

    /// Only the controls themselves take touches; the empty space around them
    /// passes through to the player's own controls.
    private func controls(showsStatistics: Bool) -> some View {
        VStack(spacing: 8) {
            if controlsVisible {
                overlay
                    .transition(.opacity)
                    // Using a control keeps the row up.
                    .simultaneousGesture(TapGesture().onEnded { controlsTouch += 1 })
            }
            if let notice = visibleNotice {
                Text(notice).font(.caption).foregroundStyle(Palette.primaryText)
                    .padding(8).playerChip()
            }
            if model.resolvingIndex != nil {
                Label("正在恢复播放…", systemImage: "arrow.clockwise")
                    .font(.footnote).foregroundStyle(Palette.primaryText)
                    .padding(8).playerChip()
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
            if !isUpright {
                // Upright, 关闭 sits in the score strip under the picture.
                Button { session.isPresented = false } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold))
                        .padding(8)
                        .playerChip()
                }
                .accessibilityLabel("关闭播放器")
            }
            if !model.resolvedChannels.isEmpty {
                ChannelMenu(model: model)
            }

            PlayerInsightsControls(model: model.insights, showsStatistics: $showsStatistics, showsToggle: !isUpright)
            if isPhoneSideways {
                Button { withAnimation(.snappy) { showsStatistics = false }; Orientation.leaveFullScreen() } label: {
                    Label("竖屏", systemImage: "iphone")
                        .font(.footnote.weight(.semibold))
                        .padding(8)
                        .playerChip()
                }
                .accessibilityLabel("竖屏看数据")
            }
            RecordControl(model: model)

            // Cropping only means something once the picture fills the
            // screen. Upright it is a 16:9 box, and an expand-arrows glyph
            // there read as a second 全屏 next to the real one.
            if !isUpright {
                Button {
                    session.fillsScreen.toggle()
                } label: {
                    Label(session.fillsScreen ? "完整" : "铺满",
                          systemImage: session.fillsScreen ? "rectangle.arrowtriangle.2.inward" : "crop")
                        .font(.footnote.weight(.semibold))
                        .padding(8)
                        .playerChip()
                }
                .accessibilityLabel(session.fillsScreen ? "完整画面" : "铺满屏幕")
            }
        }
        .foregroundStyle(Palette.primaryText)
        .padding(.top, 10)
    }
}

/// Hosts the session's long-lived controller. SwiftUI may tear this wrapper
/// down and rebuild it; the controller, and any Picture in Picture it owns,
/// stays with the session.
///
/// Turning the phone moves the picture into a different layout, so a new
/// container appears while the old one is still being torn down. Each
/// container therefore wraps the controller instead of being it: the newest
/// one adopts it, and an old one only lets go if it still holds it.
private struct PlayerContainer: UIViewControllerRepresentable {
    let controller: AVPlayerViewController
    /// A tap on the picture, which also toggles AVKit's own controls.
    var onTap: () -> Void = {}

    func makeUIViewController(context: Context) -> PlayerHost { PlayerHost(player: controller) }
    func updateUIViewController(_ host: PlayerHost, context: Context) {
        host.onTap = onTap
        host.adopt()
    }
    static func dismantleUIViewController(_ host: PlayerHost, coordinator: ()) { host.release() }
}

private final class PlayerHost: UIViewController, UIGestureRecognizerDelegate {
    let player: AVPlayerViewController
    var onTap: () -> Void = {}

    init(player: AVPlayerViewController) {
        self.player = player
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Watch taps alongside AVKit's own recogniser rather than taking them.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
        adopt()
    }

    @objc private func tapped() { onTap() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        adopt()
    }

    func adopt() {
        guard isViewLoaded, player.parent !== self else { return }
        if player.parent != nil {
            player.willMove(toParent: nil)
            player.view.removeFromSuperview()
            player.removeFromParent()
        }
        addChild(player)
        player.view.frame = view.bounds
        player.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(player.view)
        player.didMove(toParent: self)
    }

    func release() {
        guard player.parent === self else { return }
        player.willMove(toParent: nil)
        player.view.removeFromSuperview()
        player.removeFromParent()
    }
}

private struct PlayerInsightsControls: View {
    @ObservedObject var model: MatchInsightsModel
    @Binding var showsStatistics: Bool
    /// Upright, the statistics are already under the picture.
    var showsToggle = true
    var body: some View {
        HStack(spacing: 8) {
            if model.mid != nil {
                Button { model.danmakuEnabled.toggle() } label: {
                    Image(systemName: model.danmakuEnabled ? "captions.bubble.fill" : "captions.bubble")
                        .padding(8).playerChip()
                }.accessibilityLabel(model.danmakuEnabled ? "关闭弹幕" : "开启弹幕")
            }
            if showsToggle {
                Button { withAnimation(.snappy) { showsStatistics.toggle() } } label: {
                    Label("数据", systemImage: "chart.bar.xaxis")
                        .font(.footnote.weight(.semibold)).padding(8)
                        .foregroundStyle(showsStatistics ? Palette.onAccent : Palette.primaryText)
                        .playerChip(highlighted: showsStatistics)
                }
            }
        }
    }
}

/// Which channel is playing and whether priority picked it. Opening it lists
/// the channels best-first, as a manual override; automatic fallback keeps
/// working either way.
private struct ChannelMenu: View {
    @ObservedObject var model: MatchPlaybackModel

    var body: some View {
        Menu {
            Section("按优先级自动选择，失效会自动换下一条") {
                ForEach(model.rankedChannelIndices, id: \.self) { index in
                    let source = model.resolvedChannels[index]
                    Button {
                        guard index != model.playback?.index else { return }
                        Task { await model.startManualPlayback(at: index) }
                    } label: {
                        if index == model.playback?.index {
                            Label {
                                Text(source.name)
                                Text(model.choseManually ? "手动 · 播放中" : "自动 · 播放中")
                            } icon: { Image(systemName: "checkmark") }
                        } else {
                            Text(source.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.choseManually ? "hand.tap" : "checkmark")
                    .foregroundStyle(model.choseManually ? Palette.accent : Palette.healthy)
                Text("\(model.choseManually ? "手动" : "自动") · \(model.playback?.sourceName ?? "线路")")
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .playerChip()
        }
        .accessibilityLabel("线路：\(model.playback?.sourceName ?? "未选择")")
    }
}

extension View {
    /// Warm smoked-glass chip for controls over the picture.
    func playerChip(highlighted: Bool = false) -> some View {
        background(highlighted ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color(hex: 0x1A1714).opacity(0.72)),
                   in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(hex: 0xFFECD2).opacity(0.16), lineWidth: 0.5))
    }
}
