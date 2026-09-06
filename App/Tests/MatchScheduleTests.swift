import XCTest
#if os(tvOS)
@testable import JRKANTV
#else
@testable import JRKANiOS
#endif

final class MatchScheduleTests: XCTestCase {
    private let beijing = TimeZone(identifier: "Asia/Shanghai")!

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.timeZone = beijing
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)!
    }

    func testKickoffUsesCurrentYearInBeijingTime() {
        let now = date("2026-09-05 18:00")
        XCTAssertEqual(MatchSchedule.kickoff(from: "09-05 20:00", now: now), date("2026-09-05 20:00"))
    }

    func testKickoffSnapsAcrossNewYear() {
        XCTAssertEqual(
            MatchSchedule.kickoff(from: "01-02 03:00", now: date("2026-12-31 23:00")),
            date("2027-01-02 03:00")
        )
        XCTAssertEqual(
            MatchSchedule.kickoff(from: "12-31 23:00", now: date("2027-01-01 01:00")),
            date("2026-12-31 23:00")
        )
    }

    func testStatusBuckets() {
        let now = date("2026-09-05 20:30")
        XCTAssertEqual(MatchSchedule.status(for: "09-05 20:00", now: now), .unknown)
        XCTAssertEqual(MatchSchedule.status(for: "09-05 21:15", now: now), .upcoming(startsInMinutes: 45))
        XCTAssertEqual(MatchSchedule.status(for: "09-05 16:00", now: now), .unknown)
        XCTAssertEqual(MatchSchedule.status(for: "待定", now: now), .unknown)
    }

    func testDisplayTimeConvertsToViewerZone() {
        let now = date("2026-09-05 18:00")
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let shown = MatchSchedule.displayTime(for: "09-05 23:30", now: now, timeZone: tokyo)
        XCTAssertEqual(shown.day, "明天")
        XCTAssertEqual(shown.clock, "00:30")

        let local = MatchSchedule.displayTime(for: "09-05 23:30", now: now, timeZone: beijing)
        XCTAssertEqual(local.day, "今天")
        XCTAssertEqual(local.clock, "23:30")
    }

    func testFollowedFilterMatchesEitherTeam() {
        let match = LiveMatch(
            id: "1", league: "NBA", time: "09-05 20:00",
            homeTeam: "湖人", awayTeam: "凯尔特人",
            homeLogoURL: nil, awayLogoURL: nil, isHot: false, sources: []
        )
        XCTAssertTrue(SportFilter.followed.includes(match, favorites: ["凯尔特人"]))
        XCTAssertFalse(SportFilter.followed.includes(match, favorites: ["勇士"]))
    }

    func testElapsedKickoffNeverProvesLiveOrFinished() {
        let now = date("2026-09-05 22:50")
        for league in ["美职联", "NBA", "未知联赛"] {
            XCTAssertEqual(MatchSchedule.status(for: "09-05 20:30", league: league, now: now), .unknown)
        }
    }

    func testProviderStateOverridesElapsedKickoffForOvertimeAndPostponement() {
        let now = date("2026-09-06 10:30")
        var match = LiveMatch(id: "one", league: "美职联", time: "09-06 07:30",
            homeTeam: "Home", awayTeam: "Away", homeLogoURL: nil, awayLogoURL: nil,
            isHot: false, sources: [])
        func state(_ code: Int, sport: Int = 1) -> ProviderMatchState {
            ProviderMatchState(sportID: sport, code: code, periodStartedAt: now, updatedAt: now)
        }
        match.providerState = state(4)
        XCTAssertEqual(MatchSchedule.status(for: match, now: now), .live(label: "加时赛"))
        match.providerState = state(6)
        XCTAssertEqual(MatchSchedule.status(for: match, now: now), .live(label: "点球大战"))
        match.providerState = state(8)
        XCTAssertEqual(MatchSchedule.status(for: match, now: now), .interrupted(label: "推迟"))
        match.providerState = state(7)
        XCTAssertEqual(MatchSchedule.status(for: match, now: now), .finished)
        match.providerState = state(8, sport: 2)
        XCTAssertEqual(MatchSchedule.status(for: match, now: now), .live(label: "加时"))
        match.providerState = state(9, sport: 2)
        XCTAssertEqual(MatchSchedule.status(for: match, now: now), .finished)
        match.providerState = state(0)
        XCTAssertEqual(MatchSchedule.status(for: match, now: now), .scheduled)
    }

    func testPeriodClockUsesSecondHalfStartAndExpiresWhenStale() {
        let now = date("2026-09-06 10:30")
        let state = ProviderMatchState(sportID: 1, code: 3,
            periodStartedAt: now.addingTimeInterval(-8 * 60), updatedAt: now)
        XCTAssertEqual(state.status(now: now), .live(label: "53′"))
        XCTAssertNil(state.status(now: now.addingTimeInterval(10 * 60)))
        let stoppage = ProviderMatchState(sportID: 1, code: 3,
            periodStartedAt: now.addingTimeInterval(-51 * 60), updatedAt: now)
        XCTAssertEqual(stoppage.status(now: now), .live(label: "90+"))
        XCTAssertEqual(ProviderMatchState(sportID: 1, code: 2,
            periodStartedAt: now, updatedAt: now).status(now: now), .live(label: "中场休息"))
    }
}

final class EventSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_663_314)

    private func payload(rows: [[Any]], timestamp: Double = 1_788_663_314) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "success": true, "time": timestamp,
            "list": ["fields": ["id", "sportid", "status", "st_first", "st_second"], "values": rows]
        ])
        return "jrkanEvents(\(String(decoding: data, as: UTF8.self)));"
    }

    private func match(_ id: String) -> LiveMatch {
        LiveMatch(id: id, league: "Test", time: "09-06 07:30", homeTeam: "Home", awayTeam: "Away",
            homeLogoURL: nil, awayLogoURL: nil, isHot: false,
            sources: [MatchSource(id: "one", name: "Channel", pageURL: URL(string: "https://fixture.example/play")!)])
    }

    func testEventSnapshotMatchesCompositeIDsAndKeepsChannelChoices() throws {
        let response = try payload(rows: [
            [101, 1, 3, 1_788_658_800_000, 1_788_662_771_000],
            [101, 2, 0, 1_788_663_600_000, 1_788_663_600_000]
        ])
        let snapshot = try EventSnapshot.parse(response, now: now)
        let input = [match("101,1,101"), match("101,2,101"), match("102,1,102"), match("other")]
        let output = snapshot.applying(to: input)
        XCTAssertEqual(output.map(\.id), ["101,1,101", "101,2,101", "other"])
        XCTAssertEqual(output[0].providerState?.code, 3)
        XCTAssertEqual(output[1].providerState?.code, 0)
        XCTAssertEqual(output[0].sources, input[0].sources)
        XCTAssertEqual(output[1].time, "09-06 11:00")
    }

    func testRejectsStaleOrMalformedSnapshotInsteadOfClearingSchedule() throws {
        XCTAssertThrowsError(try EventSnapshot.parse(payload(rows: [], timestamp: now.timeIntervalSince1970 - 601), now: now))
        XCTAssertThrowsError(try EventSnapshot.parse(payload(rows: [[101, 1]]), now: now))
        XCTAssertThrowsError(try EventSnapshot.parse("jrkanEvents({\"success\":false})", now: now))
        XCTAssertThrowsError(try EventSnapshot.parse("jrkanEvents([\"invalid\",\"UMY=\"])", now: now))
    }

    func testDiscoversWebsiteConfigurationWithoutHardcodingItsHost() {
        let base = URL(string: "https://site.example/")!
        let html = #"document.write("<script src='//data.example/tmp/njs.js?_t="+Math.random());"#
        XCTAssertEqual(EventSnapshot.configURL(in: html, baseURL: base)?.absoluteString,
            "https://data.example/tmp/njs.js")
        let config = #"{"config":{"base_zqlq_url":"//data.example/tmp/event?type=zqlq"}}"#
        XCTAssertEqual(EventSnapshot.eventURL(in: config, baseURL: base)?.absoluteString,
            "https://data.example/tmp/event?type=zqlq&callback=jrkanEvents")
    }

    func testDecodesWebsiteEncryptedEnvelope() throws {
        let encrypted = "3N36qZhpphxYmdWBDeQb08YkwJCCunTowCuPexJi40p9eZeQ32NEFTUBghA5sSC4b2noY5MLY2WjkwUAvkRy6KLPB5+G9kKXmIC077s4DEi7jwJnkLKgDQzLC64ogCWZ2Fh25qmtgtzKgbriuGiI/RfJesyAipD00k9K14zZyCn4RsmL6+gcDnW2QCFTDbZQf0h5TdTgaJEM0gIam3iWeA=="
        let snapshot = try EventSnapshot.parse("jrkanEvents([\"\(encrypted)\",\"UMY=\"])", now: now)
        XCTAssertEqual(snapshot.events["1,101"]?.state.code, 3)
        XCTAssertEqual(snapshot.events["1,101"]?.state.status(now: now), .live(label: "54′"))
    }

    func testClientAppliesEventsAndFallsBackToScheduleOnEventFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EventFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let live = try await JRSClient(homepageURL: URL(string: "https://valid.example/")!, session: session).fetchMatches()
        XCTAssertEqual(live.map(\.id), ["101,1,101"])
        XCTAssertEqual(MatchSchedule.status(for: live[0]), .live(label: "加时赛"))
        let fallback = try await JRSClient(homepageURL: URL(string: "https://unavailable.example/")!, session: session).fetchMatches()
        XCTAssertEqual(fallback.count, 2)
        XCTAssertTrue(fallback.allSatisfy { $0.providerState == nil && !$0.sources.isEmpty })
    }
}

private final class EventFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let text: String
        switch url.path {
        case "/":
            text = "<script src=\"/index.js\"></script><script src=\"https://\(url.host!)/tmp/njs.js\"></script>"
        case "/index.js":
            text = [101, 102].map { id in
                """
                document.write('<ul class="item play" data-lid="\(id),1,\(id)">');
                document.write('<li class="lab_events"><span class="name">League</span></li>');
                document.write('<li class="lab_time">09-06 07:30</li>');
                document.write('<li class="lab_team_home"><strong class="name">Home</strong><img src="https://fixture.example/home.png"></li>');
                document.write('<li class="lab_team_away"><strong class="name">Away</strong><img src="https://fixture.example/away.png"></li>');
                document.write('<a class="item ok" href="https://fixture.example/play"><strong>Channel</strong></a>');
                document.write('</ul>');
                """
            }.joined(separator: "\n")
        case "/tmp/njs.js":
            text = #"{"config":{"base_zqlq_url":"/tmp/event?type=zqlq"}}"#
        case "/tmp/event":
            if url.host == "unavailable.example" {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                return
            }
            let now = Date().timeIntervalSince1970
            text = "jrkanEvents({\"success\":true,\"time\":\(now),\"list\":{\"fields\":[\"id\",\"sportid\",\"status\",\"st_first\",\"st_second\"],\"values\":[[101,1,4,\((now - 10800) * 1000),\(now * 1000)]]}})"
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
