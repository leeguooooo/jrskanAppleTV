import SwiftUI

@main
struct JRKANApp: App {
    @StateObject private var model = MatchListModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MatchListView()
                .environmentObject(model)
                .environmentObject(model.preferences)
                .task {
                    await model.loadIfNeeded()
                    model.startAutoRefresh()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back from the Home screen after a while: the
                    // schedule on screen is stale, and the viewer expects
                    // "now" without having to find the refresh button.
                    guard phase == .active else { return }
                    Task { await model.refreshIfStale() }
                }
        }
    }
}
