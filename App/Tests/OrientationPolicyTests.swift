#if os(iOS)
import UIKit
import XCTest
@testable import JRKANiOS

final class OrientationPolicyTests: XCTestCase {
    func testPhoneScreensStayPhoneShapedInEveryOrientation() {
        // Portrait iPhone, landscape iPhone, landscape Plus / Pro Max.
        XCTAssertTrue(Orientation.isPhoneShaped(idiom: .phone, horizontal: .compact, vertical: .regular))
        XCTAssertTrue(Orientation.isPhoneShaped(idiom: .phone, horizontal: .compact, vertical: .compact))
        XCTAssertTrue(Orientation.isPhoneShaped(idiom: .phone, horizontal: .regular, vertical: .compact))
    }

    func testOpenIPhoneDuoRotatesFreely() {
        XCTAssertFalse(Orientation.isPhoneShaped(idiom: .phone, horizontal: .regular, vertical: .regular))
    }

    func testPhonePlayerFollowsThePhoneUntilFullScreen() {
        let phone = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceIdiom: .phone),
            UITraitCollection(horizontalSizeClass: .compact),
            UITraitCollection(verticalSizeClass: .regular),
        ])
        XCTAssertEqual(Orientation.defaultMask(for: phone), .portrait)
        XCTAssertEqual(Orientation.playerMask(for: phone), .allButUpsideDown)
        AppDelegate.playerFullScreen = true
        defer { AppDelegate.playerFullScreen = false }
        XCTAssertEqual(Orientation.playerMask(for: phone), .landscape)
    }

    func testOpenIPhoneDuoPlayerRotatesFreely() {
        let duo = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceIdiom: .phone),
            UITraitCollection(horizontalSizeClass: .regular),
            UITraitCollection(verticalSizeClass: .regular),
        ])
        XCTAssertEqual(Orientation.playerMask(for: duo), .all)
        XCTAssertEqual(Orientation.defaultMask(for: duo), .all)
    }

    func testIPadAndMacAreNeverLocked() {
        XCTAssertFalse(Orientation.isPhoneShaped(idiom: .pad, horizontal: .compact, vertical: .regular))
        XCTAssertFalse(Orientation.isPhoneShaped(idiom: .pad, horizontal: .regular, vertical: .regular))
        XCTAssertFalse(Orientation.isPhoneShaped(idiom: .mac, horizontal: .regular, vertical: .regular))
    }
}
#endif
