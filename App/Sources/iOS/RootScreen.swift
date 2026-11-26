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
    @ObservedObject private var coverPlayer = CoverPlayerPresence.shared
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
        // Replays and recordings play in their own full-screen covers, deep in
        // the compact stack, and turn the phone to landscape too. On a Pro Max
        // or Air that is a regular width: switching layouts there tore down
        // the stack and the cover with it. Hold the layout until the phone is
        // upright again.
        .onChange(of: coverPlayer.isPresented) { _, presented in
            if presented {
                heldCompact = heldCompact ?? fitsCompact
            } else if let held = heldCompact, held == fitsCompact, !session.isPresented {
                heldCompact = nil
            }
        }
        .onChange(of: fitsCompact) { _, _ in releaseHeldLayout() }
        .onReceive(coverPlayer.objectWillChange) { _ in
            DispatchQueue.main.async { if !coverPlayer.isPresented { releaseHeldLayout() } }
        }
        .fullScreenCover(isPresented: $session.isPresented) {
            if let model = session.model {
                TouchPlayerScreen(session: session, model: model)
            }
        }
    }

    private func releaseHeldLayout() {
        guard let held = heldCompact, !session.isPresented else { return }
        if held == fitsCompact { heldCompact = nil; return }
        // A cover player stays held until the phone has turned back upright.
        guard !coverPlayer.isPresented, !coverPlayer.isTurningBack else { return }
        if !Orientation.isTurningBackToPortrait { heldCompact = nil }
    }
}

/// A full-screen player other than the live one (replays, recordings) is up.
/// RootScreen holds its layout while this is set, as it does for the live player.
@MainActor
final class CoverPlayerPresence: ObservableObject {
    static let shared = CoverPlayerPresence()
    @Published private(set) var isPresented = false
    /// Closed on a phone that is still turning back to portrait.
    private(set) var isTurningBack = false

    /// Call before the cover turns the phone to landscape.
    func playerAppeared() {
        isTurningBack = false
        isPresented = true
    }

    /// Call as the cover goes, before Orientation.restoreDefault().
    func playerDisappeared() {
        isTurningBack = Orientation.isTurningBackToPortrait
        isPresented = false
        if isTurningBack {
            // Upright again by then; a phone left sideways is released too.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.isTurningBack = false
                self.objectWillChange.send()
            }
        }
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
