import SwiftUI

@main
struct JRKANApp: App {
    @StateObject private var model = MatchListModel()

    var body: some Scene {
        WindowGroup {
            MatchListView()
                .environmentObject(model)
                .task {
                    await model.loadIfNeeded()
                }
        }
    }
}
