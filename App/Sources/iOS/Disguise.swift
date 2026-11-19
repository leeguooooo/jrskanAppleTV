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
            // Dropped, not just hidden, so its comment polling stops too.
            window?.isHidden = true
            window = nil
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

/// What the disguise shows: a terminal running a coding agent. The prompt's
/// commands switch between /code (nothing but a scrolling diff, the
/// default), /comments, /score and /players for the match that is playing,
/// all dressed as the agent's output; the status line carries the score.
struct DisguiseScreen: View {
    @ObservedObject private var session = PlayerSession.shared
    @StateObject private var feed = CommentFeedModel()
    @StateObject private var spareInsights = MatchInsightsModel()

    private var match: LiveMatch? { session.model?.match }

    var body: some View {
        TerminalCommentsView(match: match, feed: feed, insights: session.model?.insights ?? spareInsights,
                             offersCode: true, paneKey: "disguisePane") { EmptyView() }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TerminalStyle.background.ignoresSafeArea())
            .contentShape(Rectangle())
            // Double-tap anywhere to go back to the match.
            .onTapGesture(count: 2) { Disguise.shared.set(false) }
            .accessibilityAction(named: "恢复") { Disguise.shared.set(false) }
            .task(id: match?.id) {
                guard let model = session.model, CommentFeedModel.hasComments(model.match) else { return }
                await feed.run(match: model.match, channels: model.resolvedChannels)
            }
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
