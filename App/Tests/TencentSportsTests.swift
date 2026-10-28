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

    func testSharedAndroidAppleContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("contracts/tencent-sports.json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for row in try XCTUnwrap(fixture["channels"] as? [[String: Any]]) {
            let source = MatchSource(id: "shared", name: row["name"] as! String, pageURL: URL(string: row["url"] as! String)!)
            XCTAssertEqual(source.playbackPriority, row["priority"] as? Int)
            XCTAssertEqual(TencentSportsClient.candidateMID(match: match(), channels: [source]), row["mid"] as? String)
        }
        let snapshot = try TencentSportsClient.parseStatistics(try XCTUnwrap(fixture["statistics"] as? [String: Any]), mid: mid)
        XCTAssertEqual(snapshot.score, "0 : —")
        XCTAssertEqual(snapshot.tables.count, 4)
        XCTAssertEqual(snapshot.tables[1].rows[1], ["篮板", "—", "1"])
        XCTAssertEqual(snapshot.playerTables[0].rows, [["77 球员甲", "1'00", "0"]])
        let comments = TencentSportsClient.parseComments(try XCTUnwrap(fixture["comments"] as? [String: Any]), mid: mid,
            now: Date(timeIntervalSince1970: (fixture["nowMs"] as! Double) / 1000))
        XCTAssertEqual(comments.map(\.id), ["keep"])
        XCTAssertEqual(comments.first?.text, "好球")
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

    @MainActor
    func testStatisticsPollAgainWithinTenSecondsAndCancelCleanly() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("contracts/tencent-sports.json"))) as! [String: Any]
        var statistics = fixture["statistics"] as! [String: Any]
        var info = statistics["teamInfo"] as! [String: Any]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = Date()
        info["startTime"] = formatter.string(from: now)
        statistics["teamInfo"] = info
        let bytes = try JSONSerialization.data(withJSONObject: ["code": 0, "data": statistics])
        let twice = expectation(description: "Two statistics polls, including request time")
        twice.expectedFulfillmentCount = 2
        InsightsPollingProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/kbs/matchStat")
            twice.fulfill()
            return bytes
        }
        defer { InsightsPollingProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InsightsPollingProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = MatchInsightsModel(client: TencentSportsClient(session: session))
        formatter.dateFormat = "MM-dd HH:mm"
        let game = LiveMatch(id: "poll", league: "NBA", time: formatter.string(from: now), homeTeam: "湖人", awayTeam: "快船",
                             homeLogoURL: nil, awayLogoURL: nil, isHot: false, sources: [])
        let channels = [MatchSource(id: "t", name: "中文高清Q", pageURL: URL(string: "https://fixture.example/play/kbs/?id=10022600102")!)]
        let task = Task { await model.watch(match: game, channels: channels) }
        defer { task.cancel() }
        await fulfillment(of: [twice], timeout: 15)
        while model.isRefreshing { await Task.yield() }
        XCTAssertNotNil(model.snapshot)
        let manual = expectation(description: "Manual refresh does not wait for the next poll")
        InsightsPollingProtocol.handler = { _ in manual.fulfill(); return bytes }
        await model.refresh()
        await fulfillment(of: [manual], timeout: 1)
        XCTAssertFalse(model.isRefreshing)
        task.cancel()
        await task.value
        XCTAssertEqual(model.status, "")
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

private final class InsightsPollingProtocol: URLProtocol {
    static var handler: ((URLRequest) -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let bytes = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
}
