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
    }

    var body: some Scene {
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
                .task { await account.refreshIfStale() }
                .task { await AppConfigStore.shared.refreshIfStale() }
                // @Published fires before the new value lands; read it on the next turn.
                .onReceive(account.$stored) { _ in
                    Task { @MainActor in AppConfigStore.shared.isMember = account.isMember }
                }
                .task {
                    model.startAutoRefresh()
                    await model.loadIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
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
