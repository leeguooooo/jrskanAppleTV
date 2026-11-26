import XCTest
#if os(tvOS)
@testable import JRKANTV
#else
@testable import JRKANiOS
#endif

/// Weibo replay parsing against contracts/weibo-replay.json (trimmed live
/// responses from 2026-11-26), shared with the Android ReplayTest.
final class ReplayTests: XCTestCase {
    private let rules = ReplayRules()

    private func fixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("contracts/weibo-replay.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    private func beijing(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = ReplayParsing.beijing
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    func testUploaderFeedKeepsOnlyRecordings() throws {
        let feed = ReplayParsing.waterfall(try XCTUnwrap(fixture()["waterfall"] as? [String: Any]), rules: rules)
        XCTAssertEqual(feed.nextCursor, "5369096449295542")
        XCTAssertEqual(feed.videos.count, 11, "short highlight clips are dropped")
        let full = try XCTUnwrap(feed.videos.first { $0.id == "Rt8axdsAW" })
        XCTAssertEqual(full.matchup, ReplayVideo.Matchup(left: "热火", right: "76人"))
        XCTAssertEqual(full.part, .full)
        XCTAssertEqual(full.titledDay, beijing("2026-11-26 00:00"))
        XCTAssertEqual(full.author, "花查章")
        XCTAssertEqual(full.coverURL?.scheme, "https")
        XCTAssertEqual(feed.videos.first { $0.id == "Rt8ybrfxz" }?.part, .secondHalf)
        XCTAssertEqual(feed.videos.first { $0.id == "Rt7vGnFxj" }?.part, .firstHalf)
        // A football game posted three days later keeps its titled day.
        let football = try XCTUnwrap(feed.videos.first { $0.id == "Rt3yvoUza" })
        XCTAssertEqual(football.matchup, ReplayVideo.Matchup(left: "巴塞罗那", right: "比利亚雷亚尔"))
        XCTAssertEqual(football.gameDay, beijing("2026-11-22 00:00"))
    }

    func testSearchMatchesFixtureBothWaysAndOrdersWholeGameFirst() throws {
        let found = ReplayParsing.search(try XCTUnwrap(fixture()["search"] as? [String: Any]), rules: rules)
        XCTAssertFalse(found.isEmpty)
        XCTAssertTrue(found.allSatisfy { !$0.text.contains("<") }, "HTML stripped")
        // The listing calls it 76人 (home) vs 热火; uploaders write 热火vs76人.
        let matched = ReplayParsing.videos(for: "76人", away: "热火", kickoff: beijing("2026-11-26 08:00"), in: found, rules: rules)
        XCTAssertEqual(matched.first?.part, .full)
        XCTAssertEqual(matched.map(\.part.order), matched.map(\.part.order).sorted())
        XCTAssertTrue(matched.contains { $0.part == .period(4) })
        // Another day's meeting of the same teams is not this match.
        XCTAssertTrue(ReplayParsing.videos(for: "76人", away: "热火", kickoff: beijing("2026-12-20 08:00"), in: found, rules: rules).isEmpty)
        XCTAssertTrue(ReplayParsing.videos(for: "湖人", away: "热火", kickoff: beijing("2026-11-26 08:00"), in: found, rules: rules).isEmpty)
    }

    func testOldSeasonUploadIsRejected() throws {
        let old = try XCTUnwrap(ReplayParsing.video(
            id: "old", author: "x", authorID: "1", postedAt: beijing("2024-04-18 12:00"),
            rawText: "热火vs76人中文解说全场超清回放", duration: 7000, coverURL: nil, rules: rules))
        XCTAssertEqual(old.part, .full)
        XCTAssertTrue(ReplayParsing.videos(for: "76人", away: "热火", kickoff: beijing("2026-11-26 08:00"), in: [old], rules: rules).isEmpty)
        let undatedSameDay = try XCTUnwrap(ReplayParsing.video(
            id: "new", author: "篮球之声", authorID: "2358578625", postedAt: beijing("2026-11-26 09:37"),
            rawText: "热火vs76人 http://t.cn/AXTRyK8T", duration: 11170, coverURL: nil, rules: rules))
        XCTAssertEqual(undatedSameDay.part, .full, "game-length with no label counts as the whole game")
        XCTAssertEqual(ReplayParsing.videos(for: "76人", away: "热火", kickoff: beijing("2026-11-26 08:00"), in: [undatedSameDay], rules: rules).count, 1)
    }

    func testMatchupAndPartParsing() {
        let cases: [(String, String, String)] = [
            ("nba杯东部小组赛：热火vs76人 第二节回放！", "热火", "76人"),
            ("11月25日2026-2027赛季NBA杯 独行侠vs掘金全场高清回放", "独行侠", "掘金"),
            ("赛季NBA杯热火vs76人全场回放", "热火", "76人"),
            ("#热火vs76人# 下半场录像", "热火", "76人"),
            ("湖人 VS 爵士 中文解说全场", "湖人", "爵士"),
        ]
        for (text, left, right) in cases {
            XCTAssertEqual(ReplayParsing.matchup(in: text), ReplayVideo.Matchup(left: left, right: right), text)
        }
        XCTAssertNil(ReplayParsing.matchup(in: "盘点NBA最疯狂的压哨绝杀名场面！"))
        XCTAssertEqual(ReplayParsing.part(of: "热火vs76人 第3节回放", duration: 1700, rules: rules), .period(3))
        XCTAssertEqual(ReplayParsing.part(of: "热火vs76人 第四节回放", duration: 1700, rules: rules), .period(4))
        XCTAssertEqual(ReplayParsing.part(of: "热火vs76人下半场录像回放", duration: 4044, rules: rules), .secondHalf)
        XCTAssertEqual(ReplayParsing.part(of: "热火vs76人", duration: 2000, rules: rules), .other)
        XCTAssertNil(ReplayParsing.video(id: "hl", author: "", authorID: "", postedAt: Date(), rawText: "热火vs76人 回放",
                                         duration: 58, coverURL: nil, rules: rules), "highlight length")
        XCTAssertNil(ReplayParsing.video(id: "top", author: "", authorID: "", postedAt: Date(), rawText: "热火vs76人 十佳球集锦回放",
                                         duration: 900, coverURL: nil, rules: rules))
    }

    func testPlainTextDropsVideoLinkLabel() {
        let html = #"11月26日 热火vs76人 第1节回放 <a  href="https://m.weibo.cn/search?containerid=231522">#热火vs76人#</a> <a href='https://video.weibo.com/show?fid=1034:1'><span class="surl-text">JamesLebron的微博视频</span></a> &amp; more"#
        XCTAssertEqual(ReplayParsing.plainText(html), "11月26日 热火vs76人 第1节回放 #热火vs76人# & more")
    }

    func testStreamsBestFirstHttpsOnly() throws {
        let streams = ReplayParsing.streams(try XCTUnwrap(fixture()["show"] as? [String: Any]))
        XCTAssertEqual(streams.map(\.height), [1080, 720, 480], "scrubber image dropped")
        XCTAssertTrue(streams.allSatisfy { $0.url.scheme == "https" })
        XCTAssertNotNil(streams.first?.expires)
    }

    func testGroupsMergeUploadsOfOneGame() throws {
        let fx = try fixture()
        let videos = ReplayParsing.waterfall(try XCTUnwrap(fx["waterfall"] as? [String: Any]), rules: rules).videos
            + ReplayParsing.search(try XCTUnwrap(fx["search"] as? [String: Any]), rules: rules)
        let groups = ReplayParsing.groups(videos)
        XCTAssertEqual(groups.first?.title, "热火 vs 76人")
        XCTAssertEqual(groups.first?.videos.first?.part, .full)
        XCTAssertEqual(Set(groups.first?.videos.map(\.id) ?? []).count, groups.first?.videos.count, "no duplicates")
        XCTAssertEqual(groups.first { $0.title == "独行侠 vs 掘金" }?.videos.count, 4)
        XCTAssertEqual(groups.map(\.day), groups.map(\.day).sorted(by: >))
    }

    func testRemoteConfigReplayBlock() throws {
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8)).replay, AppConfig.Replay())
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("""
        {"replay":{"enabled":false,"uploaders":["abc"],"minDuration":1,"windowHours":1000,"searchSuffix":" 录像"}}
        """.utf8))
        XCTAssertFalse(config.replay.enabled)
        XCTAssertEqual(config.replay.uploaders, AppConfig.Replay().uploaders)
        XCTAssertEqual(config.replay.minDuration, 60)
        XCTAssertEqual(config.replay.windowHours, 240)
        XCTAssertEqual(config.replay.searchSuffix, " 录像")
    }
}
