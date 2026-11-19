import AppIntents
import SwiftUI
import UIKit

/// 一键伪装: a terminal with an AI agent writing code, in a window above
/// everything else (the list, the full-screen player, sheets). The stream
/// keeps playing underneath, sound included; the status line still carries
/// the score. Double-tap the disguise, tap the player's button again, or
/// run the 伪装 / 恢复 shortcut (bindable to Back Tap) to come back.
///
/// On iPhone and iPad the same screen also covers the app whenever it
/// leaves the foreground, so the app switcher's snapshot shows code, not
/// the match. The Mac keeps its own tools (dimming, code veil, comments
/// window) and has no app switcher snapshot to hide.
@MainActor
final class Disguise: ObservableObject {
    static let shared = Disguise()

    /// The viewer asked for the disguise.
    @Published private(set) var isOn = false
    /// Shown only because the app left the foreground.
    private var coversForBackground = false
    private var window: UIWindow?

    func toggle() { set(!isOn) }

    func set(_ on: Bool) {
        isOn = on
        coversForBackground = false
        apply()
    }

    /// The app is about to leave the foreground (app switcher, home,
    /// Control Center): cover it before the system takes its snapshot.
    func appWillResignActive() {
        #if !targetEnvironment(macCatalyst)
        guard !isOn else { return }
        coversForBackground = true
        apply()
        #endif
    }

    func appDidBecomeActive() {
        guard coversForBackground else { return }
        coversForBackground = false
        apply()
    }

    private func apply() {
        guard isOn || coversForBackground else {
            window?.isHidden = true
            return
        }
        guard let scene = Self.activeScene() else { return }
        if window?.windowScene !== scene {
            let cover = UIWindow(windowScene: scene)
            cover.windowLevel = .alert + 1
            cover.overrideUserInterfaceStyle = .dark
            let host = UIHostingController(rootView: DisguiseScreen())
            host.view.backgroundColor = UIColor(TerminalStyle.background)
            cover.rootViewController = host
            window = cover
        }
        window?.isHidden = false
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}

/// What the disguise shows: a terminal running a coding agent.
struct DisguiseScreen: View {
    @ObservedObject private var session = PlayerSession.shared
    @State private var tick = 0
    @State private var started = Date()
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("~/work/service").foregroundStyle(TerminalStyle.bullet)
                Text(" (main) ").foregroundStyle(TerminalStyle.dim)
                Text("% agent").foregroundStyle(TerminalStyle.text)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            CodeVeil(strength: 1)
            statusLine
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            HStack(spacing: 6) {
                Text("❯").foregroundStyle(TerminalStyle.text)
                Rectangle().fill(TerminalStyle.text.opacity(tick.isMultiple(of: 2) ? 0.8 : 0)).frame(width: 7, height: 14)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(TerminalStyle.faint.opacity(0.6)).frame(height: 1) }
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TerminalStyle.background.ignoresSafeArea())
        .contentShape(Rectangle())
        // Double-tap anywhere to go back to the match.
        .onTapGesture(count: 2) { Disguise.shared.set(false) }
        .onReceive(clock) { _ in tick += 1 }
        .statusBarHidden(false)
        .accessibilityAction(named: "恢复") { Disguise.shared.set(false) }
    }

    /// The agent's status line; the score rides along as token counts
    /// (主队↑ 客队↓), so it can still be followed while disguised.
    private var statusLine: some View {
        let glyphs = ["✻", "✶", "✳", "✢", "·", "✢", "✳", "✶"]
        var parts = ["\(Int(Date().timeIntervalSince(started)))s"]
        if let snapshot = session.model?.insights.snapshot {
            let scores = snapshot.score.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            if scores.count == 2 { parts.append("\(scores[0])↑ \(scores[1])↓ tokens") }
        }
        parts.append("esc to interrupt")
        return HStack(spacing: 0) {
            Text(glyphs[tick % glyphs.count] + " ").foregroundStyle(TerminalStyle.bullet)
            Text("Working… ").foregroundStyle(TerminalStyle.dim)
            Text("(" + parts.joined(separator: " · ") + ")").foregroundStyle(TerminalStyle.faint)
        }
        .lineLimit(1)
    }
}

/// 伪装 / 恢复 as a shortcut, so it can be put on Back Tap
/// (设置 › 辅助功能 › 触控 › 轻点背面) and fired without touching the screen.
struct ToggleDisguiseIntent: AppIntent {
    static let title: LocalizedStringResource = "伪装 / 恢复"
    static let description = IntentDescription("leeguoo sports 在前台时，切到伪装画面；再运行一次切回来。")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        Disguise.shared.toggle()
        return .result()
    }
}

struct LeeguooShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleDisguiseIntent(),
                    phrases: ["\(.applicationName) 伪装", "\(.applicationName) 恢复"],
                    shortTitle: "伪装 / 恢复",
                    systemImageName: "terminal")
    }
}
