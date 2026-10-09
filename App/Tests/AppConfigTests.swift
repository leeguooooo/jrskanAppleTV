import XCTest
#if os(tvOS)
@testable import JRKANTV
#else
@testable import JRKANiOS
#endif

final class AppConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }

    func testDecodesWorkerResponse() throws {
        let config = try decode("""
        {"version":1,"watermark":{"enabled":true,"texts":["leeguoo.com","世界杯直播"],"motion":"drift","interval":45,"opacity":0.4,"hideForMembers":true},
         "slots":{"home_banner":{"enabled":true,"title":"欧冠决赛","detail":"今晚 3 点","url":"https://leeguoo.com/a","hideForMembers":true}}}
        """)
        XCTAssertEqual(config.watermark.texts, ["leeguoo.com", "世界杯直播"])
        XCTAssertEqual(config.watermark.motion, .drift)
        XCTAssertEqual(config.watermark.interval, 45)
        XCTAssertEqual(config.slot("home_banner", isMember: false)?.link?.absoluteString, "https://leeguoo.com/a")
        XCTAssertNil(config.slot("home_banner", isMember: true))
        XCTAssertNil(config.visibleWatermark(isMember: true))
        XCTAssertNotNil(config.visibleWatermark(isMember: false))
    }

    func testFallsBackFieldByField() throws {
        let config = try decode("""
        {"watermark":{"texts":[],"motion":"spin","interval":1,"opacity":"x"},"slots":{"home_banner":{"enabled":true,"title":""},"later":{"enabled":true,"title":"新广告位","url":"http://plain"}},"future":42}
        """)
        XCTAssertEqual(config.watermark.texts, ["leeguoo.com"])
        XCTAssertEqual(config.watermark.motion, .drift)
        XCTAssertEqual(config.watermark.interval, 5)
        XCTAssertEqual(config.watermark.opacity, 0.55)
        XCTAssertNil(config.slot("home_banner", isMember: false), "no title, nothing to show")
        XCTAssertEqual(config.slot("later", isMember: false)?.title, "新广告位")
        XCTAssertNil(config.slot("later", isMember: false)?.link, "only https links open")
        XCTAssertEqual(try decode("{}"), AppConfig())
    }
}

@MainActor
final class WatermarkViewTests: XCTestCase {
    func testShowsConfiguredTextInsideTheView() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        let view = WatermarkView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        try await Task.sleep(nanoseconds: 300_000_000)
        view.layoutIfNeeded()
        let label = try XCTUnwrap(view.subviews.first as? UILabel)
        XCTAssertFalse(label.isHidden)
        XCTAssertEqual(label.text, "leeguoo.com")
        XCTAssertGreaterThan(label.alpha, 0.1)
        XCTAssertGreaterThan(label.bounds.width, 0)
        XCTAssertTrue(view.bounds.contains(label.frame), "\(label.frame) outside \(view.bounds)")
    }
}
