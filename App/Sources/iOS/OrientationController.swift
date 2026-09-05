import SwiftUI
import UIKit

/// The list is a portrait screen; the player is a landscape one. iOS only
/// lets a view controller *permit* orientations, so the app delegate holds
/// the current mask and the player flips it and asks the scene to rotate.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = defaultMask

    static var defaultMask: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

enum Orientation {
    /// Lock to landscape and turn the screen if it is not already there.
    static func enterLandscape() {
        AppDelegate.orientationLock = .landscape
        request(.landscapeRight, allowing: .landscape)
    }

    static func restoreDefault() {
        AppDelegate.orientationLock = AppDelegate.defaultMask
        request(.portrait, allowing: AppDelegate.defaultMask)
    }

    private static func request(_ orientation: UIInterfaceOrientationMask, allowing mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        // On iPad the default mask already covers landscape; do not shove the
        // screen back to portrait when the player closes.
        let target = mask.contains(orientation) && !(mask == .all && orientation == .portrait) ? orientation : mask
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.keyWindow?.rootViewController?.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
