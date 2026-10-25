import SwiftUI

/// Picks the layout by how much width the app actually has, not by device:
/// an iPhone, the closed iPhone Duo, a Slide Over pane and a narrow Catalyst
/// window get the compact stack, while the open iPhone Duo, a full-screen iPad
/// or a normal Mac window gets the three-column split. Folding, multitasking
/// and window resizing all change this at runtime, so it follows the size
/// class rather than being decided once at launch.
///
/// A Plus / Pro Max is regular in landscape too, and the player forces
/// landscape there. The layout is held while the player is up and until the
/// phone has turned back, so playback does not flip the screen behind it.
///
/// The player is presented from here, above both layouts, so a layout change
/// never takes the stream with it; `LayoutHandoff` carries the open match
/// across so the new layout reopens it.
struct RootScreen: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var session = PlayerSession.shared
    @ObservedObject private var handoff = LayoutHandoff.shared
    @State private var heldCompact: Bool?

    private var fitsCompact: Bool { horizontalSizeClass != .regular }
    private var isCompact: Bool { heldCompact ?? fitsCompact }

    var body: some View {
        Group {
            if isCompact {
                CompactHomeScreen()
            } else {
                RegularMatchListScreen()
            }
        }
        .onChange(of: isCompact) { _, _ in handoff.pending = handoff.openMatch }
        .onChange(of: session.isPresented) { _, presented in
            if presented { heldCompact = fitsCompact } else { releaseHeldLayout() }
        }
        .onChange(of: fitsCompact) { _, _ in releaseHeldLayout() }
        .fullScreenCover(isPresented: $session.isPresented) {
            if let model = session.model {
                TouchPlayerScreen(session: session, model: model)
            }
        }
    }

    private func releaseHeldLayout() {
        guard let held = heldCompact, !session.isPresented else { return }
        if held == fitsCompact || !Orientation.isTurningBackToPortrait { heldCompact = nil }
    }
}

/// The match open in whichever layout is showing. The compact stack keeps a
/// path per tab and the split view keeps a selection; neither survives the
/// other replacing it, so each reports what it has open here and the layout
/// that takes over adopts `pending` once.
@MainActor
final class LayoutHandoff: ObservableObject {
    static let shared = LayoutHandoff()

    var openMatch: LiveMatch?
    /// Set on a layout switch, cleared by the layout that reopens it.
    @Published var pending: LiveMatch?

    func take() -> LiveMatch? {
        defer { pending = nil }
        return pending
    }
}
