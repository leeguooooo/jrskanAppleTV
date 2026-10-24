import XCTest
#if os(tvOS)
@testable import JRKANTV
#else
@testable import JRKANiOS
#endif

final class TencentSportsTests: XCTestCase {
    private let mid = "100000:10022600102"
    private func match(sources: [MatchSource] = []) -> LiveMatch {
        LiveMatch(id: "3931544,2,3931544", league: "NBA", time: "10-24 10:00", homeTeam: "湖人", awayTeam: "快船",
                  homeLogoURL: nil, awayLogoURL: nil, isHot: false, sources: sources)
    }

    func testComparisonBarsPreserveZerosAndRejectMissingAndInvalidValues() {
        XCTAssertEqual(SportsStatComparison(row: ["得分", "60", "40"])?.leftShare, 0.6)
        XCTAssertEqual(SportsStatComparison(row: ["命中率", "40% (4/10)", "60% (6/10)"])?.leftShare, 0.4)
        XCTAssertEqual(SportsStatComparison(row: ["得分", "0", "0"])?.leftShare, 0.5)
        XCTAssertNil(SportsStatComparison(row: ["得分", "—", "0"]))
        XCTAssertNil(SportsStatComparison(row: ["得分", "NaN", "4"]))
    }

    func testMappingUsesSourceEventIDAndRejectsConflictingEvents() {
        func source(_ id: String) -> MatchSource {
            MatchSource(id: id, name: "中文高清", pageURL: URL(string: "https://play.example/play/kbs/?id=\(id)&id2=")!)
        }
        XCTAssertEqual(TencentSportsClient.candidateMID(match: match(), channels: [source("10022600102")]), mid)
        XCTAssertNil(TencentSportsClient.candidateMID(match: match(), channels: [source("10022600102"), source("10022600103")]))
        XCTAssertNil(TencentSportsClient.candidateMID(match: match(), channels: [source("439")]))
        let alternateTencent = MatchSource(id: "txf", name: "中文高清⑤", pageURL:
            URL(string: "https://play.example/play/txf/?id=10022600101&id2=")!)
        XCTAssertEqual(TencentSportsClient.candidateMID(match: match(), channels: [alternateTencent]), "100000:10022600101")
    }

    func testMatchingRequiresTeamsStartTimeAndExactEventID() {
        let now = ISO8601DateFormatter().date(from: "2026-10-24T02:00:00Z")!
        var info: [String: Any] = ["mid": mid, "leftName": "快船", "rightName": "湖人", "startTime": "2026-10-24 10:00:00"]
        XCTAssertTrue(TencentSportsClient.matches(info, match: match(), mid: mid, now: now))
        info["rightName"] = "勇士"
        XCTAssertFalse(TencentSportsClient.matches(info, match: match(), mid: mid, now: now))
        info["rightName"] = "湖人"; info["startTime"] = "2026-10-25 10:00:00"
        XCTAssertFalse(TencentSportsClient.matches(info, match: match(), mid: mid, now: now))
        info["startTime"] = "2026-10-24 10:00:00"; info["mid"] = "100000:other"
        XCTAssertFalse(TencentSportsClient.matches(info, match: match(), mid: mid, now: now))
    }

    func testCommentsFilterWrongMatchStaleGiftsDuplicatesAndMarkup() {
        let now = Date(timeIntervalSince1970: 1_000)
        func comment(_ id: String, _ stamp: String, event: String? = nil, type: String = "0") -> [String: Any] {
            ["commentId": id, "postTime": stamp, "mid": event ?? mid, "type": type, "content": "<b>好球</b>[打call/]\n"]
        }
        let data: [String: Any] = ["list": [comment("ok", "990"), comment("ok", "990"), comment("old", "100"),
            comment("wrong", "990", event: "another"), comment("gift", "990", type: "2"), comment("future", "2000")]]
        let parsed = TencentSportsClient.parseComments(data, mid: mid, now: now)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.text, "好球")
    }

    func testStatisticsPreserveColumnOrderMissingValuesAndZero() throws {
        let data: [String: Any] = [
            "teamInfo": ["leftName": "快船", "rightName": "湖人", "leftGoal": "0", "quarterDesc": "第一节"],
            "periodGoals": ["head": ["1st", "总分"], "rows": [["-", "0", "0"], ["-", "2", "2"]]],
            "teamStats": [["text": "得分", "leftVal": "0", "rightVal": "2"], ["text": "篮板", "rightVal": "1"]],
            "playerStats": ["left": [["head": ["号码/球员", "时间", "得分"]],
                                      ["row": ["77", "球员甲", "1'00", "0"]], ["row": ["broken"]]]]
        ]
        let snapshot = try TencentSportsClient.parseStatistics(data, mid: mid)
        XCTAssertEqual(snapshot.score, "0 : —")
        XCTAssertEqual(snapshot.tables[0].rows[0], ["快船", "0", "0"])
        XCTAssertEqual(snapshot.tables[1].rows[1], ["篮板", "—", "1"])
        XCTAssertEqual(snapshot.tables[2].rows, [["77 球员甲", "1'00", "0"]])
        XCTAssertThrowsError(try TencentSportsClient.parseStatistics([:], mid: mid))
    }

    func testLivePublicStatisticsAndCommentContract() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_JRS_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_JRS_TESTS=1 for public Tencent contracts.")
        }
        let matches = try await JRSClient().fetchMatches()
        let client = TencentSportsClient()
        for match in matches.filter({ $0.league == "NBA" }).prefix(8) {
            guard let page = match.sources.first?.pageURL,
                  let channels = try? await SourcePageClient().fetchChannels(from: page),
                  let candidate = TencentSportsClient.candidateMID(match: match, channels: channels) else { continue }
            try await client.verify(match: match, mid: candidate)
            let snapshot = try await client.statistics(mid: candidate, match: match)
            XCTAssertFalse(snapshot.tables.isEmpty)
            _ = try await client.comments(mid: candidate)
            return
        }
        throw XCTSkip("No current NBA fixture exposes a Tencent event ID.")
    }
}
