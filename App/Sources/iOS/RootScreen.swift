import SwiftUI

/// Picks the layout by how much width the app actually has, not by device
/// name: an iPhone, a Slide Over pane and a narrow Catalyst window all get the
/// compact stack, while a full-screen iPad or a normal Mac window gets the
/// three-column split. iPad multitasking changes this at runtime, so it has to
/// be driven by the size class rather than decided once at launch.
///
/// A phone is always compact, though. A Plus / Pro Max turns regular in
/// landscape, and the player forces landscape: swapping the root layout there
/// tore down the detail screen and its player the moment playback started.
///
/// The player is presented from here, above both layouts, so a layout change
/// (iPad multitasking, a Mac window resize) never takes the stream with it.
struct RootScreen: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var session = PlayerSession.shared

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact {
                CompactHomeScreen()
            } else {
                RegularMatchListScreen()
            }
        }
        .fullScreenCover(isPresented: $session.isPresented) {
            if let model = session.model {
                TouchPlayerScreen(session: session, model: model)
            }
        }
    }
}
