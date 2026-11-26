import AVFoundation
import SwiftUI

@main
struct JRKANiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = MatchListModel()
    @StateObject private var account = AccountSession.launchDefault()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Without the playback category the ring/silent switch mutes the
        // stream and audio stops when the phone locks.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        Self.applyScoreboardChrome()
    }

    /// Large titles in the heading face and cream text on every bar; the
    /// titles are fixed strings, which is all the subset heading face covers.
    private static func applyScoreboardChrome() {
        let cream = UIColor(Palette.primaryText)
        let navigation = UINavigationBar.appearance()
        var large: [NSAttributedString.Key: Any] = [.foregroundColor: cream]
        if let heading = UIFont(name: "LeeguooHeading-Black", size: 32) {
            large[.font] = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: heading)
        }
        navigation.largeTitleTextAttributes = large
        navigation.titleTextAttributes = [.foregroundColor: cream]
    }

    var body: some Scene {
        #if targetEnvironment(macCatalyst)
        mainWindow
            .commands {
                PictureCommands()
                // One main window only: a second one would share the single player.
                CommandGroup(replacing: .newItem) {}
            }

        WindowGroup("评论", id: CommentsWindow.sceneID, for: String.self) { $matchID in
            CommentsWindowScreen(matchID: matchID)
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
        }
        #else
        mainWindow
        #endif
    }

    private var mainWindow: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if DebugRoute.raw == "account" {
                    NavigationStack { AccountScreen() }
                } else if DebugRoute.raw?.hasPrefix("recordings") == true {
                    NavigationStack { RecordingsScreen() }
                } else {
                    RootScreen()
                }
                #else
                RootScreen()
                #endif
            }
                .environmentObject(model)
                .environmentObject(model.preferences)
                .environmentObject(account)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
                #if targetEnvironment(macCatalyst)
                // No app name across the top of the window on a work screen.
                .background(WindowProbe { $0.titlebar?.titleVisibility = .hidden })
                #endif
                .task { await account.refreshIfStale() }
                .task { await AppConfigStore.shared.refreshIfStale() }
                // Loads the recordings and finishes any MP4 export cut short last time.
                .task { _ = RecordingCenter.shared }
                // Replay downloads carry on (and their offline copies play) from launch.
                .task { _ = ReplayDownloadCenter.shared }
                // @Published fires before the new value lands; read it on the next turn.
                .onReceive(account.$stored) { _ in
                    Task { @MainActor in AppConfigStore.shared.isMember = account.isMember }
                }
                .task {
                    model.startAutoRefresh()
                    await model.loadIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Cover the app before the app switcher snapshots it.
                    if phase == .inactive { Disguise.shared.appWillResignActive() }
                    if phase == .active { Disguise.shared.appDidBecomeActive() }
                    if phase == .active {
                        RecordingCenter.shared.appWillEnterForeground()
                        model.startAutoRefresh()
                        Task { await model.refreshIfStale() }
                        Task { await account.refreshIfStale() }
                        Task { await AppConfigStore.shared.refreshIfStale() }
                    } else if phase == .background {
                        RecordingCenter.shared.appDidEnterBackground()
                        model.stopAutoRefresh()
                    }
                }
        }
    }
}

#if targetEnvironment(macCatalyst)
/// The 画面 menu in the Mac menu bar. Its shortcuts work whenever the app is
/// in front, including while the player has the keyboard; ⌘H still hides the
/// whole app and the stream keeps playing.
private struct PictureCommands: Commands {
    var body: some Commands {
        CommandMenu("画面") {
            Button("画面调暗") { PlayerSession.shared.adjustDimming(by: 0.1) }
                .keyboardShortcut("[", modifiers: .command)
            Button("画面调亮") { PlayerSession.shared.adjustDimming(by: -0.1) }
                .keyboardShortcut("]", modifiers: .command)
            Button("恢复原亮度") {
                PlayerSession.shared.isCovered = false
                PlayerSession.shared.dimming = 0
            }
            Button("代码伪装 开 / 关") {
                let session = PlayerSession.shared
                session.setCodeVeil(on: session.codeVeil == 0)
            }
            .keyboardShortcut("'", modifiers: .command)
            Divider()
            Button("评论字号放大") { TerminalStyle.adjustSize(by: 1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("评论字号缩小") { TerminalStyle.adjustSize(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
            Divider()
            Button("遮住 / 显示画面（声音继续）") { PlayerSession.shared.isCovered.toggle() }
                .keyboardShortcut("\\", modifiers: .command)
        }
    }
}
#endif
