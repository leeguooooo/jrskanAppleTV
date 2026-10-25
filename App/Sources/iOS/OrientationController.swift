import SwiftUI
import UIKit

/// On a phone-shaped screen the list is a portrait screen. The player follows
/// the phone: upright it shows the picture on top and the statistics below,
/// turned sideways it fills the screen. Its full-screen button locks
/// landscape until the viewer asks for the upright layout again. iOS only lets a view controller *permit* orientations, so
/// the app delegate answers from whether the player is up and the shape of
/// the screen the window is on now: folding iPhone Duo moves a playing match
/// from the inner display to the phone-shaped outer one.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var playerIsUp = false
    /// The viewer pressed full screen: hold landscape even if the phone is upright.
    static var playerFullScreen = false

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        let traits = window?.windowScene?.traitCollection
        return Self.playerIsUp ? Orientation.playerMask(for: traits) : Orientation.defaultMask(for: traits)
    }
}

enum Orientation {
    /// Whether the app is on a phone-sized screen, where the list stays
    /// upright and the player turns the screen. The open iPhone Duo is
    /// regular both ways, like an iPad: it rotates freely and plays in
    /// whatever shape the viewer holds it. A Plus / Pro Max in landscape is
    /// regular wide but compact tall, so it still counts as a phone.
    ///
    /// The idiom only keeps iPad and Mac Catalyst out: a narrow multitasking
    /// pane there is compact too, and rotating the device for it is wrong.
    static func isPhoneShaped(
        idiom: UIUserInterfaceIdiom,
        horizontal: UIUserInterfaceSizeClass,
        vertical: UIUserInterfaceSizeClass
    ) -> Bool {
        idiom == .phone && !(horizontal == .regular && vertical == .regular)
    }

    static func defaultMask(for traits: UITraitCollection?) -> UIInterfaceOrientationMask {
        isPhoneShaped(traits) ? .portrait : .all
    }

    static func playerMask(for traits: UITraitCollection?) -> UIInterfaceOrientationMask {
        guard isPhoneShaped(traits) else { return .all }
        return AppDelegate.playerFullScreen ? .landscape : .allButUpsideDown
    }

    /// The player is up: let a phone-shaped screen follow the phone.
    static func enterPlayer() {
        AppDelegate.playerIsUp = true
        AppDelegate.playerFullScreen = false
        guard let scene = activeScene else { return }
        request(playerMask(for: scene.traitCollection), in: scene)
    }

    /// Full screen on a phone: turn to landscape and hold it there.
    static func enterFullScreen() {
        guard AppDelegate.playerIsUp, let scene = activeScene, isPhoneShaped(scene.traitCollection) else { return }
        AppDelegate.playerFullScreen = true
        request(.landscapeRight, in: scene)
    }

    /// A player with nothing to show beside the picture (recordings):
    /// landscape, held.
    static func enterLandscape() {
        enterPlayer()
        enterFullScreen()
    }

    /// Back to the upright picture-and-statistics layout.
    static func leaveFullScreen() {
        guard AppDelegate.playerIsUp, let scene = activeScene, isPhoneShaped(scene.traitCollection) else { return }
        AppDelegate.playerFullScreen = false
        request(.portrait, in: scene)
    }

    /// The player's screen changed shape, as when iPhone Duo is folded or
    /// unfolded mid-match: apply the mask for the screen it is on now,
    /// keeping whichever landscape side the viewer already holds.
    static func fitPlayer() {
        guard AppDelegate.playerIsUp, let scene = activeScene else { return }
        request(playerMask(for: scene.traitCollection), in: scene)
    }

    /// The player turned a phone-shaped screen to landscape and closing it
    /// will turn it back.
    static var isTurningBackToPortrait: Bool {
        AppDelegate.playerIsUp && isPhoneShaped(activeScene?.traitCollection)
    }

    static func restoreDefault() {
        guard AppDelegate.playerIsUp else { return }
        AppDelegate.playerIsUp = false
        AppDelegate.playerFullScreen = false
        guard let scene = activeScene else { return }
        // Closed on the open inner display: it rotates freely, so lift the
        // lock without turning it back to portrait.
        request(isPhoneShaped(scene.traitCollection) ? .portrait : .all, in: scene)
    }

    private static func isPhoneShaped(_ traits: UITraitCollection?) -> Bool {
        guard let traits else { return false }
        return isPhoneShaped(idiom: traits.userInterfaceIdiom,
                             horizontal: traits.horizontalSizeClass,
                             vertical: traits.verticalSizeClass)
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    private static func request(_ orientations: UIInterfaceOrientationMask, in scene: UIWindowScene) {
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.keyWindow?.rootViewController?.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
