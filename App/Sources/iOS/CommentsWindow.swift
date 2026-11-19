#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Mac only: the live comments of one match in a small window of their own.
/// It polls on its own, so it keeps going with the player closed, covered or
/// minimised, and it can float above other apps (置顶) and fade (透明度), so
/// the match can be followed in a corner of a work screen without a picture.
/// Comments exist only for NBA and CBA, like the danmaku.
enum CommentsWindow {
    static let sceneID = "comments"

    /// Channels already resolved by the match screen, which identify the
    /// match to the comment providers better than the homepage entries.
    @MainActor static var channels: [String: [MatchSource]] = [:]
}

/// Opens (or brings forward) the comments window for a match.
struct CommentsWindowButton: View {
    let match: LiveMatch
    let channels: [MatchSource]
    var chip = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            CommentsWindow.channels[match.id] = channels
            openWindow(id: CommentsWindow.sceneID, value: match.id)
        } label: {
            if chip {
                Label("评论小窗", systemImage: "text.bubble")
                    .font(.footnote.weight(.semibold))
                    .padding(8)
                    .playerChip()
            } else {
                Label("只看评论（小窗，可置顶）", systemImage: "text.bubble")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityLabel("打开评论小窗")
    }
}

/// Comments for the window: the providers return what was posted in the last
/// two minutes; this keeps a longer history so the window reads like a chat.
@MainActor
final class CommentFeedModel: ObservableObject {
    @Published private(set) var comments: [SportsComment] = []
    @Published private(set) var status = "正在连接评论…"
    private let client = MultiSportsClient(tencent: TencentSportsClient())
    private var seen: [String] = []

    static func hasComments(_ match: LiveMatch) -> Bool {
        ["NBA", "CBA"].contains(match.league.uppercased())
    }

    /// Polls every 10 seconds until the task is cancelled (window closed or
    /// sent to the background). Never overlaps requests.
    func run(match: LiveMatch, channels: [MatchSource]) async {
        guard Self.hasComments(match) else { status = "只有 NBA、CBA 比赛有评论"; return }
        while !Task.isCancelled {
            do {
                let batch = try await client.comments(match: match, channels: channels, excluding: Set(seen))
                try Task.checkCancellation()
                for comment in batch where !seen.contains(comment.id) {
                    comments.append(comment)
                    seen.append(comment.id)
                }
                comments = Array(comments.suffix(300))
                seen = Array(seen.suffix(1000))
                status = comments.isEmpty ? "还没有新评论，10 秒后再看" : ""
            } catch {
                if Task.isCancelled { return }
                // An empty Tencent answer falls through to Migu, which throws when
                // it has no such match: usually just a quiet comment section.
                status = comments.isEmpty ? "暂时没有评论，10 秒后再看" : ""
            }
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
        }
    }
}

struct CommentsWindowScreen: View {
    let matchID: String?
    @EnvironmentObject private var listModel: MatchListModel
    @ObservedObject private var session = PlayerSession.shared
    @StateObject private var feed = CommentFeedModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var window = MacWindowHandle()
    @State private var pinned = false
    @State private var opacity = 1.0
    /// Dressed as a terminal running an AI coding agent, so a glance at the
    /// screen reads as work. On by default; the plain look is one click away.
    @AppStorage("commentsTerminalSkin") private var terminal = true

    private var match: LiveMatch? {
        guard let matchID else { return nil }
        if let current = listModel.matches.first(where: { $0.id == matchID }) { return current }
        if let playing = session.model?.match, playing.id == matchID { return playing }
        return nil
    }

    var body: some View {
        Group {
            if terminal {
                TerminalCommentsView(match: match, feed: feed) { controls }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider().overlay(Palette.hairline)
                    content
                }
                .background(Palette.backgroundBottom.ignoresSafeArea())
                .foregroundStyle(Palette.primaryText)
            }
        }
        .background(WindowProbe { scene in window.attach(scene, title: terminal ? "zsh" : "评论") })
        .onChange(of: terminal) { _, on in window.setTitle(on ? "zsh" : "评论") }
        #if DEBUG
        // `-comments-pin` floats the window at once, to check 置顶 without a click.
        .task {
            guard CommandLine.arguments.contains("-comments-pin") else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            pinned = window.setFloating(true)
            print("comments-window pinned=\(pinned)")
        }
        #endif
        // Stops when the window closes or the app is hidden; a window that is
        // merely behind another app keeps polling, which is the point of it.
        .task(id: "\(matchID ?? "")-\(match != nil)-\(scenePhase == .background)") {
            guard scenePhase != .background, let match else { return }
            let channels = CommentsWindow.channels[match.id] ?? MatchSource.playbackOrdered(match.sources)
            await feed.run(match: match, channels: channels)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let match {
                scoreLine(match)
            } else {
                Text("评论").font(.subheadline.weight(.semibold))
            }
            Spacer(minLength: 4)
            controls
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: terminal ? 2 : 8) {
            iconButton("terminal", label: terminal ? "普通样式" : "终端样式", active: false) { terminal.toggle() }
            if session.model?.match.id == matchID, session.model?.playback != nil {
                iconButton(session.isCovered ? "eye.slash.fill" : "eye",
                           label: session.isCovered ? "显示视频画面" : "遮住视频画面（声音继续）",
                           active: session.isCovered) { session.isCovered.toggle() }
            }
            iconButton("circle.lefthalf.filled", label: "透明度 \(Int(opacity * 100))%", active: opacity < 1) {
                opacity = opacity > 0.9 ? 0.7 : opacity > 0.6 ? 0.45 : 1
                window.setAlpha(opacity)
            }
            iconButton(pinned ? "pin.fill" : "pin", label: pinned ? "取消置顶" : "置顶", active: pinned) {
                pinned = window.setFloating(!pinned)
            }
        }
    }

    private func scoreLine(_ match: LiveMatch) -> some View {
        let status = MatchSchedule.status(for: match, now: Date())
        var score: String?
        if match.scoreText != nil, let home = match.providerState?.homeScore, let away = match.providerState?.awayScore {
            score = "\(home) : \(away)"
        }
        return HStack(spacing: 6) {
            Text(match.homeTeam).lineLimit(1)
            Text(score ?? "VS").font(BrandFont.numeric(14, bold: true, relativeTo: .subheadline))
                .foregroundStyle(score == nil ? Palette.tertiaryText : Palette.primaryText)
            Text(match.awayTeam).lineLimit(1)
            if case .live(let label) = status {
                Text(label).font(.caption2).foregroundStyle(Palette.secondaryText).lineLimit(1)
            }
        }
        .font(.footnote.weight(.semibold))
        .minimumScaleFactor(0.8)
    }

    private func iconButton(_ symbol: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if terminal {
                // Faint glyphs, no chips: the terminal look has no buttons.
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .regular))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(active ? TerminalStyle.text : TerminalStyle.faint)
            } else {
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(active ? Palette.accent : Palette.secondaryText)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    @ViewBuilder
    private var content: some View {
        if match == nil {
            placeholder(matchID == nil ? "在比赛页点「只看评论」打开" : "这场比赛已不在赛程里")
        } else if feed.comments.isEmpty {
            placeholder(feed.status)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(feed.comments) { comment in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(comment.postedAt, format: .dateTime.hour().minute())
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Palette.tertiaryText)
                                Text(comment.text)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(comment.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: feed.comments.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum TerminalStyle {
    static let background = Color(hex: 0x111111)
    static let text = Color(hex: 0xD6D6D6)
    static let dim = Color(hex: 0x8A8A8A)
    static let faint = Color(hex: 0x555555)
    static let bullet = Color(hex: 0x7FA37F)
    static let font = Font.system(size: 12, design: .monospaced)
}

/// The comments as the scrollback of an AI coding agent in a terminal: each
/// comment a ⏺ line, the score folded into the agent's status line
/// (主队↑ 客队↓), a prompt with a blinking cursor at the bottom. No team
/// names, logos or colours.
private struct TerminalCommentsView<Controls: View>: View {
    let match: LiveMatch?
    @ObservedObject var feed: CommentFeedModel
    @ViewBuilder let controls: () -> Controls
    @State private var cursorOn = true
    private let blink = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("~/work/service").foregroundStyle(TerminalStyle.bullet)
                Text(" (main) ").foregroundStyle(TerminalStyle.dim)
                Text("% agent").foregroundStyle(TerminalStyle.text)
                Spacer(minLength: 4)
                controls()
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(feed.comments) { comment in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("⏺").foregroundStyle(TerminalStyle.bullet)
                                Text(comment.text).foregroundStyle(TerminalStyle.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(comment.id)
                        }
                        if feed.comments.isEmpty {
                            Text("  ⎿  " + (match == nil ? "no session" : "waiting for output…"))
                                .foregroundStyle(TerminalStyle.dim)
                        }
                        statusLine.id("status")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .onChange(of: feed.comments.last?.id) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("status", anchor: .bottom) }
                }
            }
            HStack(spacing: 6) {
                Text("❯").foregroundStyle(TerminalStyle.text)
                Rectangle().fill(TerminalStyle.text.opacity(cursorOn ? 0.8 : 0)).frame(width: 7, height: 14)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .overlay(alignment: .top) { Rectangle().fill(TerminalStyle.faint.opacity(0.6)).frame(height: 1) }
        }
        .font(TerminalStyle.font)
        .background(TerminalStyle.background.ignoresSafeArea())
        .onReceive(blink) { _ in cursorOn.toggle() }
    }

    private var statusLine: some View {
        HStack(spacing: 0) {
            Text("✻ ").foregroundStyle(TerminalStyle.dim)
            Text("Working… ").foregroundStyle(TerminalStyle.dim)
            Text("(\(statusDetail))").foregroundStyle(TerminalStyle.faint)
        }
        .padding(.top, 4)
    }

    /// e.g. "q3 · 102↑ 98↓ tokens"; only what is known.
    private var statusDetail: String {
        guard let match else { return "idle" }
        var parts: [String] = []
        if case .live(let label) = MatchSchedule.status(for: match, now: Date()) {
            parts.append(Self.period(label))
        }
        if match.scoreText != nil, let home = match.providerState?.homeScore, let away = match.providerState?.awayScore {
            parts.append("\(home)↑ \(away)↓ tokens")
        }
        parts.append("esc to interrupt")
        return parts.joined(separator: " · ")
    }

    /// 第三节 → q3, 第一节结束 → q1 end; anything else Chinese becomes "live".
    private static func period(_ label: String) -> String {
        let map = ["第一节": "q1", "第二节": "q2", "第三节": "q3", "第四节": "q4", "上半场": "h1", "下半场": "h2",
                   "中场": "ht", "加时": "ot", "节间": "break"]
        for (chinese, short) in map where label.contains(chinese) {
            let rest = label.replacingOccurrences(of: chinese, with: "")
                .replacingOccurrences(of: "结束", with: "end").trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? short : "\(short) \(rest)"
        }
        return label.unicodeScalars.contains { $0.value > 0x2E7F } ? "live" : label
    }
}

/// Reports the window scene a view lands in.
private struct WindowProbe: UIViewRepresentable {
    let found: (UIWindowScene) -> Void
    func makeUIView(context: Context) -> ProbeView { ProbeView(found: found) }
    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        let found: (UIWindowScene) -> Void
        init(found: @escaping (UIWindowScene) -> Void) {
            self.found = found
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { found(scene) }
        }
    }
}

/// The comments window's AppKit window, for what Catalyst has no API for:
/// floating above other apps and transparency. Reached only through public
/// AppKit names (`NSApplication.sharedApplication.windows`, `title`, `level`,
/// `alphaValue`, `collectionBehavior`); if it cannot be found the buttons
/// simply do nothing.
@MainActor
final class MacWindowHandle {
    private weak var scene: UIWindowScene?
    private weak var nsWindow: NSObject?
    func setTitle(_ title: String) { scene?.title = title }

    func attach(_ scene: UIWindowScene, title: String) {
        guard self.scene !== scene else { return }
        self.scene = scene
        // Small and out of the way; the title (Window menu, Mission Control)
        // says only zsh or 评论.
        scene.sizeRestrictions?.minimumSize = CGSize(width: 260, height: 180)
        scene.sizeRestrictions?.maximumSize = CGSize(width: 640, height: 1400)
        scene.titlebar?.titleVisibility = .hidden
        scene.titlebar?.toolbar = nil
        // Several comments windows may be open: tag this one with a unique
        // title just long enough to pick out its NSWindow.
        let token = "comments-" + UUID().uuidString
        scene.title = token
        Task { @MainActor in
            for _ in 0..<20 {
                if let window = Self.appKitWindows().first(where: { ($0.value(forKey: "title") as? String) == token }) {
                    nsWindow = window
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            scene.title = title
        }
    }

    /// Returns whether the window now floats.
    func setFloating(_ floating: Bool) -> Bool {
        guard let nsWindow else { return false }
        // NSFloatingWindowLevel = 3, NSNormalWindowLevel = 0.
        nsWindow.setValue(floating ? 3 : 0, forKey: "level")
        // canJoinAllSpaces (1 << 0) | fullScreenAuxiliary (1 << 8): stay
        // visible on every desktop and over a full-screen app.
        nsWindow.setValue(floating ? (1 << 0 | 1 << 8) : 0, forKey: "collectionBehavior")
        return floating
    }

    func setAlpha(_ alpha: Double) {
        nsWindow?.setValue(alpha, forKey: "alphaValue")
    }

    private static func appKitWindows() -> [NSObject] {
        guard let type = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = type.value(forKey: "sharedApplication") as? NSObject else { return [] }
        return app.value(forKey: "windows") as? [NSObject] ?? []
    }
}
#endif
