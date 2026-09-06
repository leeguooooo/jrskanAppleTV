import AVFoundation
import SwiftUI

@main
struct JRKANiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = MatchListModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Without the playback category the ring/silent switch mutes the
        // stream and audio stops when the phone locks.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootScreen()
                .environmentObject(model)
                .environmentObject(model.preferences)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
                .task {
                    await model.loadIfNeeded()
                    model.startAutoRefresh()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.refreshIfStale() }
                }
        }
    }
}
