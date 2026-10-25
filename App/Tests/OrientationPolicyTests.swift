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

    func testIPadAndMacAreNeverLocked() {
        XCTAssertFalse(Orientation.isPhoneShaped(idiom: .pad, horizontal: .compact, vertical: .regular))
        XCTAssertFalse(Orientation.isPhoneShaped(idiom: .pad, horizontal: .regular, vertical: .regular))
        XCTAssertFalse(Orientation.isPhoneShaped(idiom: .mac, horizontal: .regular, vertical: .regular))
    }
}
#endif
