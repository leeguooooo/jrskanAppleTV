import XCTest
import AVFoundation
#if os(tvOS)
@testable import JRKANTV
#else
@testable import JRKANiOS
#endif

final class PlaybackHealthTests: XCTestCase {
    func testLateFirstFrameCanFinishConfirmationAfterStartupDeadline() {
        var monitor = PlaybackHealthMonitor(now: 0)
        for halfSecond in 1...37 {
            XCTAssertNil(monitor.sample(now: Double(halfSecond) / 2, mediaTime: 0,
                playing: false, paused: false, ready: false, itemFailed: false))
        }
        for halfSecond in 38...41 {
            XCTAssertNil(monitor.sample(now: Double(halfSecond) / 2, mediaTime: Double(halfSecond - 37) / 2,
                playing: true, paused: false, ready: true, itemFailed: false))
        }
        XCTAssertEqual(monitor.sample(now: 21, mediaTime: 2.5, playing: true, paused: false, ready: true,
            itemFailed: false), .confirmed(startupSeconds: 19))
    }

    func testContinuesMonitoringAfterFirstFrameAndDetectsFrozenPlayback() {
        var monitor = PlaybackHealthMonitor(now: 0)
        var confirmations = 0
        for second in 1...5 {
            if case .confirmed = monitor.sample(now: Double(second), mediaTime: Double(second),
                playing: true, paused: false, ready: true, itemFailed: false) { confirmations += 1 }
        }
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(monitor.confirmed)
        XCTAssertNil(monitor.sample(now: 16, mediaTime: 5, playing: true, paused: false, ready: true, itemFailed: false))
        XCTAssertEqual(monitor.sample(now: 17, mediaTime: 5, playing: true, paused: false, ready: true, itemFailed: false), .stalled)
        XCTAssertNil(monitor.sample(now: 18, mediaTime: 5, playing: true, paused: false, ready: true, itemFailed: false))
    }

    func testPauseIsNotAStallAndResumeRestartsTheWaitingWindow() {
        var monitor = PlaybackHealthMonitor(now: 0)
        for second in 1...4 {
            _ = monitor.sample(now: Double(second), mediaTime: Double(second), playing: true, paused: false, ready: true, itemFailed: false)
        }
        XCTAssertNil(monitor.sample(now: 100, mediaTime: 4, playing: false, paused: true, ready: true, itemFailed: false))
        XCTAssertNil(monitor.sample(now: 1000, mediaTime: 4, playing: false, paused: true, ready: true, itemFailed: false))
        XCTAssertNil(monitor.sample(now: 1001, mediaTime: 5, playing: true, paused: false, ready: true, itemFailed: false))
        XCTAssertNil(monitor.sample(now: 1012, mediaTime: 5, playing: false, paused: false, ready: true, itemFailed: false))
        XCTAssertEqual(monitor.sample(now: 1013, mediaTime: 5, playing: false, paused: false, ready: true, itemFailed: false), .stalled)
    }

    func testStartupNeedsActualVideoAndFailureIsImmediate() {
        var monitor = PlaybackHealthMonitor(now: 0)
        XCTAssertNil(monitor.sample(now: 19, mediaTime: 19, playing: true, paused: false, ready: false, itemFailed: false))
        XCTAssertEqual(monitor.sample(now: 20, mediaTime: 20, playing: true, paused: false, ready: false, itemFailed: false), .stalled)
        var failed = PlaybackHealthMonitor(now: 0)
        XCTAssertEqual(failed.sample(now: 1, mediaTime: .nan, playing: false, paused: true, ready: false, itemFailed: true), .stalled)
    }
}

@MainActor
final class ExperienceTests: XCTestCase {
    func testPlaybackEndNotificationsFollowOnlyTheCurrentItem() async {
        let observer = PlaybackEndObserver()
        let first = AVPlayerItem(url: URL(string: "https://fixture.example/a.m3u8")!)
        let second = AVPlayerItem(url: URL(string: "https://fixture.example/b.m3u8")!)
        let firstEnded = expectation(description: "first item ended")
        observer.observe(first) { firstEnded.fulfill() }
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: first)
        await fulfillment(of: [firstEnded], timeout: 2)
        let secondEnded = expectation(description: "current item failed to end")
        observer.observe(second) { secondEnded.fulfill() }
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: first)
        NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: second)
        await fulfillment(of: [secondEnded], timeout: 2)
        observer.stop()
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: second)
    }

    private func source(_ index: Int) -> MatchSource {
        MatchSource(id: "\(index)", name: "Line \(index)", pageURL: URL(string: "https://experience.example/\(index).m3u8")!)
    }
    private func match(_ id: String = "1,1,1") -> LiveMatch {
        LiveMatch(id: id, league: "League", time: "09-06 12:00", homeTeam: "Home", awayTeam: "Away",
            homeLogoURL: nil, awayLogoURL: nil, isHot: false, sources: [source(0), source(1), source(2)])
    }
    private func preferences() -> (Preferences, UserDefaults, String) {
        let name = UUID().uuidString
        let store = UserDefaults(suiteName: name)!
        return (Preferences(store: store), store, name)
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExperienceProtocol.self]
        return URLSession(configuration: config)
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Asynchronous playback transition did not complete")
    }

    func testRankingUsesSuccessLatencyAndTemporaryFailureCooldown() {
        let (prefs, store, name) = preferences()
        defer { store.removePersistentDomain(forName: name) }
        let sources = [source(0), source(1), source(2)]
        prefs.recordPlaybackFailure(source: sources[0])
        XCTAssertEqual(prefs.rankedIndices(for: sources, matchID: "new").first, 1)
        prefs.recordPlaybackSuccess(match: match("a"), source: sources[1], index: 1, startup: 8)
        prefs.recordPlaybackSuccess(match: match("b"), source: sources[2], index: 2, startup: 2)
        XCTAssertEqual(prefs.rankedIndices(for: sources, matchID: "new").first, 2)
        XCTAssertEqual(prefs.rankedIndices(for: sources, matchID: "a").first, 1)
        prefs.recordPlaybackFailure(source: sources[1])
        XCTAssertEqual(prefs.rankedIndices(for: sources, matchID: "a").first, 2)
    }

    func testHistoryPersistsOnlyMatchEntrancesAndIsBoundedAndClearable() {
        let (prefs, store, name) = preferences()
        defer { store.removePersistentDomain(forName: name) }
        for index in 0..<12 {
            var item = match("\(index)")
            item.providerState = ProviderMatchState(sportID: 1, code: 3, periodStartedAt: Date(), updatedAt: Date())
            prefs.recordPlaybackSuccess(match: item, source: source(0), index: 0, startup: 1)
        }
        let restored = Preferences(store: store)
        XCTAssertEqual(restored.recentWatches.count, 10)
        XCTAssertEqual(restored.recentWatches.first?.id, "11")
        XCTAssertNil(restored.recentWatches.first?.match.providerState)
        XCTAssertEqual(restored.recentWatches.first?.match.sources, match().sources)
        restored.clearHistory()
        XCTAssertFalse(restored.hasHistory)
        XCTAssertTrue(Preferences(store: store).recentWatches.isEmpty)
    }

    func testResolutionAloneDoesNotCreateHistoryAndConfirmedCallbacksAreIdempotent() async {
        let (prefs, store, name) = preferences()
        defer { store.removePersistentDomain(forName: name) }
        let session = session()
        defer { session.invalidateAndCancel() }
        let model = MatchPlaybackModel(match: match(), preferences: prefs, resolver: StreamResolver(session: session))
        await model.startPlayback(at: 0)
        XCTAssertNotNil(model.playback)
        XCTAssertTrue(prefs.recentWatches.isEmpty)
        XCTAssertNil(prefs.lastChannel(for: match().id))
        model.confirmPlayback(requestID: UUID(), startupSeconds: 1)
        XCTAssertTrue(prefs.recentWatches.isEmpty)
        let id = model.playback!.id
        model.confirmPlayback(requestID: id, startupSeconds: 1)
        model.confirmPlayback(requestID: id, startupSeconds: 1)
        XCTAssertEqual(prefs.recentWatches.count, 1)
        XCTAssertEqual(prefs.channelPerformance[source(0).pageURL.absoluteString]?.successes, 1)
        model.stopPlayback()
    }

    func testMidstreamFailureReconnectsOnceThenSwitchesAndIgnoresOldCallbacks() async throws {
        let (prefs, store, name) = preferences()
        defer { store.removePersistentDomain(forName: name) }
        let session = session()
        defer { session.invalidateAndCancel() }
        let model = MatchPlaybackModel(match: match(), preferences: prefs, resolver: StreamResolver(session: session))
        await model.startPlayback(at: 0)
        let first = try XCTUnwrap(model.playback)
        model.confirmPlayback(requestID: first.id, startupSeconds: 1)
        let now = Date()
        model.handleStall("Disconnected", requestID: first.id, now: now)
        try await waitUntil { model.playback?.id != first.id }
        let reconnected = try XCTUnwrap(model.playback)
        XCTAssertEqual(reconnected.index, 0)
        model.confirmPlayback(requestID: reconnected.id, startupSeconds: 1)
        model.handleStall("Disconnected again", requestID: reconnected.id, now: now.addingTimeInterval(10))
        try await waitUntil { model.playback?.index == 1 }
        let next = try XCTUnwrap(model.playback)
        model.handleStall("Late old event", requestID: reconnected.id)
        XCTAssertEqual(model.playback?.id, next.id)
        model.stopPlayback()
    }

    func testScoreRefreshIsIndependentAndPreservesDataOnFailureAndOlderResponses() async throws {
        let (prefs, store, name) = preferences()
        defer { store.removePersistentDomain(forName: name) }
        let session = session()
        defer { session.invalidateAndCancel() }
        let host = UUID().uuidString.lowercased() + ".example"
        let time = Date().timeIntervalSince1970 - 5
        ExperienceProtocol.configure(host, score: 1, time: time)
        let model = MatchListModel(client: JRSClient(homepageURL: URL(string: "https://\(host)/")!, session: session), preferences: prefs)
        await model.refresh()
        XCTAssertEqual(model.matches.first?.scoreText, "1 - 0")
        let scheduleTime = model.lastUpdated
        let scoreTime = model.scoresUpdatedAt
        let homeRequests = ExperienceProtocol.count(host, path: "/")
        ExperienceProtocol.configure(host, score: 1, time: time, failEvents: true)
        await model.refreshScores()
        XCTAssertEqual(model.matches.first?.scoreText, "1 - 0")
        XCTAssertEqual(model.scoresUpdatedAt, scoreTime)
        XCTAssertNotNil(model.scoreNotice)
        XCTAssertEqual(ExperienceProtocol.count(host, path: "/"), homeRequests)
        ExperienceProtocol.configure(host, score: 2, time: time + 1)
        await model.refreshScores()
        XCTAssertEqual(model.matches.first?.scoreText, "2 - 0")
        XCTAssertEqual(model.lastUpdated, scheduleTime)
        XCTAssertNil(model.scoreNotice)
        ExperienceProtocol.configure(host, score: 9, time: time)
        await model.refreshScores()
        XCTAssertEqual(model.matches.first?.scoreText, "2 - 0")
        ExperienceProtocol.configure(host, score: 2, time: time + 1, failEvents: true)
        await model.refresh()
        XCTAssertEqual(model.matches.first?.scoreText, "2 - 0")
        XCTAssertEqual(model.scoresUpdatedAt, Date(timeIntervalSince1970: time + 1))
        ExperienceProtocol.configure(host, score: 3, time: time + 2, failSchedule: true)
        await model.refresh()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.matches.first?.scoreText, "3 - 0")
    }

    func testStatisticsAndContinueUseLatestEventSnapshot() async throws {
        let (prefs, store, name) = preferences()
        defer { store.removePersistentDomain(forName: name) }
        let session = session()
        defer { session.invalidateAndCancel() }
        let host = UUID().uuidString.lowercased() + ".example"
        ExperienceProtocol.configure(host, score: 2, time: Date().timeIntervalSince1970)
        prefs.recordPlaybackSuccess(match: match(), source: source(0), index: 0, startup: 1)
        let model = MatchListModel(client: JRSClient(homepageURL: URL(string: "https://\(host)/")!, session: session), preferences: prefs)
        XCTAssertNil(model.continueMatch)
        await model.refresh()
        XCTAssertEqual(model.continueMatch?.scoreText, "2 - 0")
        XCTAssertEqual(model.matches.first?.providerState?.halftimeText, "1 - 0")
        XCTAssertEqual(model.matches.first?.providerState?.cornersText, "6 - 3")
        model.filter = .recent
        XCTAssertEqual(model.filteredMatches.first?.scoreText, "2 - 0")
        XCTAssertEqual(model.sections.first?.title, "最近观看")
        XCTAssertTrue(model.availableFilters.contains(.recent))
        var firstHalf = try XCTUnwrap(model.matches.first?.providerState)
        firstHalf = ProviderMatchState(sportID: 1, code: 1, periodStartedAt: Date(), updatedAt: Date(), homeHalfScore: 1, awayHalfScore: 0, homeCorners: -1, awayCorners: 0)
        XCTAssertNil(firstHalf.halftimeText)
        XCTAssertNil(firstHalf.cornersText)
        let basketball = ProviderMatchState(sportID: 2, code: 5, periodStartedAt: Date(), updatedAt: Date(),
            homeScore: 54, awayScore: 58, homeHalfScore: 0, awayHalfScore: 0)
        XCTAssertNil(basketball.halftimeText)
        XCTAssertEqual(basketball.basketballSummary?.difference, 4)
        XCTAssertEqual(basketball.basketballSummary?.total, 112)
    }
}

private final class ExperienceProtocol: URLProtocol {
    private struct State { var score: Int; var time: Double; var failEvents: Bool; var failSchedule: Bool }
    private static let lock = NSLock()
    private static var states: [String: State] = [:]
    private static var requests: [String: Int] = [:]
    static func configure(_ host: String, score: Int, time: Double, failEvents: Bool = false, failSchedule: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        states[host] = State(score: score, time: time, failEvents: failEvents, failSchedule: failSchedule)
    }
    static func count(_ host: String, path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests[host + path] ?? 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        Self.lock.lock()
        let state = Self.states[url.host!] ?? State(score: 1, time: Date().timeIntervalSince1970, failEvents: false, failSchedule: false)
        Self.requests[url.host! + url.path, default: 0] += 1
        Self.lock.unlock()
        var status = 200
        let body: String
        switch url.path {
        case "/":
            status = state.failSchedule ? 503 : 200
            body = "<script src=\"/index.js\"></script><script src=\"https://\(url.host!)/tmp/njs.js\"></script>"
        case "/index.js":
            body = """
            document.write('<ul class="item play" data-lid="1,1,1">');
            document.write('<li class="lab_events"><span class="name">League</span></li>');
            document.write('<li class="lab_time">09-06 12:00</li>');
            document.write('<li class="lab_team_home"><strong class="name">Home</strong><img src="https://fixture.example/home.png"></li>');
            document.write('<li class="lab_team_away"><strong class="name">Away</strong><img src="https://fixture.example/away.png"></li>');
            document.write('<a class="item ok" href="https://experience.example/0.m3u8"><strong>Line 0</strong></a>');
            document.write('</ul>');
            """
        case "/tmp/njs.js": body = #"{"base_zqlq_url":"/tmp/event?type=zqlq"}"#
        case "/tmp/event":
            status = state.failEvents ? 503 : 200
            let payload: [String: Any] = ["success": true, "time": state.time, "list": [
                "fields": ["id", "sportid", "status", "st_first", "st_second", "s1", "s2", "hs1", "hs2", "corner1", "corner2"],
                "values": [[1, 1, 3, (state.time - 3600) * 1000, (state.time - 600) * 1000, state.score, 0, 1, 0, 6, 3]]]]
            body = String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        default:
            body = "#EXTM3U\n#EXTINF:5,\nsegment.ts\n"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
