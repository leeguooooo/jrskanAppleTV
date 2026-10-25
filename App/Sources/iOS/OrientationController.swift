import SwiftUI
import UIKit

/// On a phone-shaped screen the list is a portrait screen and the player a
/// landscape one. iOS only lets a view controller *permit* orientations, so
/// the app delegate answers from whether the player is up and the shape of
/// the screen the window is on now: folding iPhone Duo moves a playing match
/// from the inner display to the phone-shaped outer one.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var playerIsUp = false

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
        isPhoneShaped(traits) ? .landscape : .all
    }

    /// The player is up: lock a phone-shaped screen to landscape and turn it.
    static func enterLandscape() {
        AppDelegate.playerIsUp = true
        guard let scene = activeScene, isPhoneShaped(scene.traitCollection) else { return }
        request(.landscapeRight, in: scene)
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
