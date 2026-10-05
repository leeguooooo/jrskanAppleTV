import SwiftUI

@main
struct JRKANApp: App {
    @StateObject private var model = MatchListModel()
    @StateObject private var account = AccountSession.launchDefault()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if DebugRoute.raw == "account" {
                    NavigationStack { AccountView() }
                } else {
                    MatchListView()
                }
                #else
                MatchListView()
                #endif
            }
                .environmentObject(model)
                .environmentObject(model.preferences)
                .environmentObject(account)
                .task { await account.refreshIfStale() }
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
                        Task { await account.refreshIfStale() }
                    } else if phase == .background {
                        model.stopAutoRefresh()
                    }
                }
        }
    }
}
