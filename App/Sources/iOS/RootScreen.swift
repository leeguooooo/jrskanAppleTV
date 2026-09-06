import SwiftUI

/// Picks the layout by how much width the app actually has, not by device
/// name: an iPhone, a Slide Over pane and a narrow Catalyst window all get the
/// compact stack, while a full-screen iPad or a normal Mac window gets the
/// three-column split. iPad multitasking changes this at runtime, so it has to
/// be driven by the size class rather than decided once at launch.
struct RootScreen: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .compact {
            CompactMatchListScreen()
        } else {
            RegularMatchListScreen()
        }
    }
}
