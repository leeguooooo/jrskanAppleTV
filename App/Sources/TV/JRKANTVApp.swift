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
                    model.startAutoRefresh()
                    await model.loadIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back from the Home screen after a while: the
                    // schedule on screen is stale, and the viewer expects
                    // "now" without having to find the refresh button.
                    if phase == .active {
                        model.startAutoRefresh()
                        Task { await model.refreshIfStale() }
                    } else if phase == .background {
                        model.stopAutoRefresh()
                    }
                }
        }
    }
}
