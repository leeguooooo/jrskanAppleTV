import XCTest
#if os(tvOS)
@testable import JRKANTV
#else
@testable import JRKANiOS
#endif

final class MultiSportsTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("contracts/multi-sports.json"))) as? [String: Any])
    }
    private func game(_ home: String = "湖人", _ away: String = "快船", _ time: String = "10-24 10:00") -> LiveMatch {
        LiveMatch(id: "test", league: "NBA", time: time, homeTeam: home, awayTeam: away, homeLogoURL: nil, awayLogoURL: nil, isHot: false, sources: [])
    }
    func testSharedMiguEspnAndCommentContractRejectsWrongMatch() throws {
        let f = try fixture(), now = Date(timeIntervalSince1970: (f["nowMs"] as! Double) / 1000)
        let m = try MultiSportsClient.miguStatistics(f["migu"] as! [String: Any], id: "120000588273", match: game(), now: now)
        XCTAssertEqual(m.sourceName, "咪咕视频"); XCTAssertEqual(m.score, "125 : 117")
        XCTAssertEqual(m.playerTables.count, 2)
        XCTAssertEqual(MultiSportsClient.miguComments(f["comments"] as! [String: Any], id: "120000588273", now: now).map(\.id), ["migu:keep"])
        XCTAssertThrowsError(try MultiSportsClient.miguStatistics(f["migu"] as! [String: Any], id: "120000588273", match: game("勇士"), now: now))
        let e = try MultiSportsClient.espnStatistics(f["espn"] as! [String: Any], id: f["espnID"] as! String, match: game("雄鹿", "公牛", "10-24 04:00"), now: now)
        XCTAssertEqual(e.sourceName, "ESPN"); XCTAssertEqual(e.playerTables.count, 2)
        XCTAssertEqual(e.playerTables.first?.headers[2], "得分")
        XCTAssertThrowsError(try MultiSportsClient.espnStatistics(f["espn"] as! [String: Any], id: "wrong", match: game("雄鹿", "公牛", "10-24 04:00"), now: now))
        XCTAssertFalse(MultiSportsClient.matches(["湖人", "勇士"], start: "202610240945", format: "yyyyMMddHHmm", match: game(), now: now))
        XCTAssertFalse(MultiSportsClient.matches(["湖人", "快船"], start: "202610250945", format: "yyyyMMddHHmm", match: game(), now: now))
    }
    func testCatalogUsesBalancedJSONAndWholeTableFallbackPreservesZeroAndOrientation() throws {
        let f = try fixture(), now = Date(timeIntervalSince1970: (f["nowMs"] as! Double) / 1000)
        let row = String(data: try JSONSerialization.data(withJSONObject: f["catalog"]!), encoding: .utf8)!
        let html = "<script>window.__INITIAL_GROUPS_STATE__ = {\"nested\":[\(row)]};window.__INITIAL_COMPS_STATE__ = {};</script>"
        XCTAssertEqual(MultiSportsClient.catalogRows(html).count, 1)
        let m = try MultiSportsClient.miguStatistics(f["migu"] as! [String: Any], id: "120000588273", match: game(), now: now)
        let t = SportsSnapshot(mid: "tencent", left: "湖人", right: "快船", score: "0 : —", period: "", tables: [SportsTable(title: "球队技术统计", headers: ["项目", "湖人", "快船"], rows: [["得分", "0", "—"]])], updatedAt: now)
        let result = try XCTUnwrap(MultiSportsClient.select([t, m]))
        XCTAssertEqual(result.score, "0 : —"); XCTAssertEqual(result.comparisonTable?.rows.first?[1], "0")
        XCTAssertEqual(result.comparisonTable?.sourceName, "腾讯体育"); XCTAssertEqual(result.playerTables.first?.sourceName, "咪咕视频")
        XCTAssertTrue(MultiSportsClient.complete(result))
        let reverse = SportsSnapshot(mid: "t", left: "快船", right: "湖人", score: "— : —", period: "", tables: [], updatedAt: now)
        let reoriented = try XCTUnwrap(MultiSportsClient.select([reverse, m]))
        XCTAssertEqual(reoriented.comparisonTable?.headers[1], "快船")
        XCTAssertEqual(reoriented.comparisonTable?.rows.first?[1], m.comparisonTable?.rows.first?[2])
        XCTAssertEqual(reoriented.periodTable?.rows.first?.first, "快船")
    }
    func testAlreadyDisplayedTencentBatchAllowsFreshMiguComments() async throws {
        let f = try fixture()
        let catalog = String(data: try JSONSerialization.data(withJSONObject: f["catalog"]!), encoding: .utf8)!
        let now = Date().timeIntervalSince1970
        let detail: [String: Any] = ["code": 0, "data": ["matchInfo": ["mid": "100000:10022600102", "leftName": "湖人", "rightName": "快船", "startTime": "2026-10-24 10:00:00"]]]
        let comments: [String: Any] = ["code": 0, "data": ["list": [["commentId": "one", "mid": "100000:10022600102", "type": "0", "postTime": now - 1, "content": "腾讯新评论"]]]]
        let migu: [String: Any] = ["code": 200, "body": ["commentInfoList": [["commentId": "two", "contentId": "120000588273", "objectId": "120000588273", "createTime": (now - 1) * 1000, "body": "咪咕新评论", "top": false]]]]
        let detailBytes = try JSONSerialization.data(withJSONObject: detail), commentBytes = try JSONSerialization.data(withJSONObject: comments), miguBytes = try JSONSerialization.data(withJSONObject: migu)
        MultiFixtureProtocol.handler = { request in
            switch request.url!.path {
            case "/kbs/matchDetail": return detailBytes
            case "/dmComment/liveList": return commentBytes
            default:
                if request.url!.path.contains("/p/home/") { return Data("<script>window.__INITIAL_GROUPS_STATE__ = {\"rows\":[\(catalog)]};</script>".utf8) }
                return miguBytes
            }
        }
        defer { MultiFixtureProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MultiFixtureProtocol.self]
        let client = MultiSportsClient(tencent: TencentSportsClient(session: URLSession(configuration: config)))
        let channels = [MatchSource(id: "t", name: "中文高清Q", pageURL: URL(string: "https://fixture.example/play/kbs/?id=10022600102")!)]
        let first = try await client.comments(match: game(), channels: channels)
        XCTAssertEqual(first.map(\.id), ["tencent:one"])
        let next = try await client.comments(match: game(), channels: channels, excluding: ["tencent:one"])
        XCTAssertEqual(next.map(\.id), ["migu:two"])
        let empty = try await client.comments(match: game(), channels: channels, excluding: ["tencent:one", "migu:two"])
        XCTAssertTrue(empty.isEmpty)
    }

    func testNetworkFallbackWithoutTencentIDAndPreferredSourceRecovery() async throws {
        let f = try fixture()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("contracts/tencent-sports.json"))) as! [String: Any]
        var preferred = previous["statistics"] as! [String: Any]
        var info = preferred["teamInfo"] as! [String: Any]; info["startTime"] = "2026-10-24 10:00:00"; preferred["teamInfo"] = info
        let catalog = String(data: try JSONSerialization.data(withJSONObject: f["catalog"]!), encoding: .utf8)!
        let migu = try JSONSerialization.data(withJSONObject: f["migu"]!)
        let tencent = try JSONSerialization.data(withJSONObject: ["code": 0, "data": preferred])
        MultiFixtureProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.url!.path.contains("/p/home/") { return Data("<script>window.__INITIAL_GROUPS_STATE__ = {\"rows\":[\(catalog)]};</script>".utf8) }
            if request.url!.path.contains("/live/statistics/") { return migu }
            return Data("{}".utf8)
        }
        defer { MultiFixtureProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MultiFixtureProtocol.self]; config.httpShouldSetCookies = false
        let client = MultiSportsClient(tencent: TencentSportsClient(session: URLSession(configuration: config)))
        let channels = [MatchSource(id: "t", name: "中文高清Q", pageURL: URL(string: "https://fixture.example/play/kbs/?id=10022600102")!)]
        let first = try await client.statistics(match: game(), channels: channels)
        XCTAssertEqual(first.sourceName, "咪咕视频")
        MultiFixtureProtocol.handler = { request in
            if request.url!.host == "matchweb.sports.qq.com" { return tencent }
            XCTFail("Healthy complete Tencent data must not request a fallback")
            return Data("{}".utf8)
        }
        let restored = try await client.statistics(match: game(), channels: channels)
        XCTAssertEqual(restored.sourceName, "腾讯体育")
        MultiFixtureProtocol.handler = { request in
            if request.url!.path.contains("/live/statistics/") { return migu }
            return Data("{}".utf8)
        }
        let noID = try await client.statistics(match: game(), channels: [])
        XCTAssertEqual(noID.sourceName, "咪咕视频")
    }

}

private final class MultiFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let bytes = Self.handler?(request) else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
}
