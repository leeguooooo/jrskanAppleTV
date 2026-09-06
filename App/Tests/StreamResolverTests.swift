import XCTest
#if os(tvOS)
@testable import JRKANTV
#else
@testable import JRKANiOS
#endif

final class StreamResolverTests: XCTestCase {
    private let resolver = StreamResolver()

    func testExtractsDirectHLSURL() {
        let pageURL = URL(string: "http://play.example/350.html")!
        let html = #"""
        <video>
          <source src="https://media.example/live/game.m3u8?token=abc&amp;expires=123">
        </video>
        """#

        XCTAssertEqual(
            resolver.extractM3U8URL(in: html, pageURL: pageURL)?.absoluteString,
            "https://media.example/live/game.m3u8?token=abc&expires=123"
        )
    }

    func testBuildsHLSURLFromPlayerHostAndID() {
        let pageURL = URL(
            string: "https://player.example/msss.html?id=/live/123.m3u8?auth_key=abc"
        )!
        let html = #"var purl = "//hdl.example.com"+id;"#

        XCTAssertEqual(
            resolver.extractM3U8URL(in: html, pageURL: pageURL)?.absoluteString,
            "https://hdl.example.com/live/123.m3u8?auth_key=abc"
        )
    }

    func testResolvesProtocolRelativeAndRelativeIframes() {
        let pageURL = URL(string: "http://play.example/play/sm.html?id=350&id2=")!
        let html = #"""
        <iframe src="//cloud.example/player.html"></iframe>
        <iframe src="/play/350.html"></iframe>
        <script>
        element.innerHTML = "<iframe src='/play/"+id1+".html'></iframe>";
        </script>
        """#

        XCTAssertEqual(
            resolver.iframeURLs(in: html, pageURL: pageURL).map(\.absoluteString),
            [
                "https://cloud.example/player.html",
                "http://play.example/play/350.html"
            ]
        )
    }

    func testDoesNotTreatPlayerWrapperQueryAsHLSMedia() {
        let pageURL = URL(string: "http://play.example/350.html")!
        let html = #"""
        <iframe src="//cloud.example/msss.html?id=/live/123.m3u8?token=abc"></iframe>
        """#

        XCTAssertNil(resolver.extractM3U8URL(in: html, pageURL: pageURL))
    }

    private let reversedHostPlayer = #"""
    function restoreStreamUrl(value) {
      const domainParts = value.split(".");
      domainParts[domainParts.length - 2] = domainParts[domainParts.length - 2]
        .split("").reverse().join("");
    }
    const id = J_get("id");
    const purl = restoreStreamUrl(id);
    """#

    func testRestoresPlayerHostAndPreservesCompleteSignedQuery() {
        let pageURL = URL(string:
            "https://player.example/msss.html?id=//cdn.elpmaxe.com:8443/live/game.m3u8?auth_key=a=b&token=xyz&device=4"
        )!
        XCTAssertEqual(
            resolver.extractM3U8URL(in: reversedHostPlayer, pageURL: pageURL)?.absoluteString,
            "https://cdn.example.com:8443/live/game.m3u8?auth_key=a=b&token=xyz&device=4"
        )
    }

    func testRestoresPercentEncodedPlayerID() {
        let pageURL = URL(string:
            "https://player.example/msss.html?id=https%3A%2F%2Fcdn.elpmaxe.com%2Flive%2Fgame.m3u8%3Ftoken%3Da%252Bb%26expires%3D123"
        )!
        XCTAssertEqual(
            resolver.extractM3U8URL(in: reversedHostPlayer, pageURL: pageURL)?.absoluteString,
            "https://cdn.example.com/live/game.m3u8?token=a%2Bb&expires=123"
        )
    }

    func testDoesNotRestoreHostWithoutPlayerTransformation() {
        let pageURL = URL(string:
            "https://player.example/msss.html?id=//cdn.elpmaxe.com/live/game.m3u8"
        )!
        XCTAssertNil(resolver.extractM3U8URL(in: "const purl = id;", pageURL: pageURL))
    }

    @MainActor
    func testFallbackDoesNotRetryFailedChannelsAfterOtherChannelsStalled() async {
        let store = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = Preferences(store: store)
        preferences.autoNextChannel = true
        let channels = (0..<5).map { index in
            MatchSource(id: "\(index)", name: "Line \(index)", pageURL:
                URL(string: index < 3 ? "https://fixture.example/\(index).html"
                    : "https://fixture.example/\(index).m3u8")!)
        }
        let match = LiveMatch(id: "fallback", league: "Test", time: "09-06 07:30",
            homeTeam: "Home", awayTeam: "Away", homeLogoURL: nil, awayLogoURL: nil,
            isHot: false, sources: channels)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnavailableStreamPage.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = MatchPlaybackModel(match: match, preferences: preferences,
            resolver: StreamResolver(session: session))

        await model.startPlayback(at: 3)
        XCTAssertEqual(model.playback?.index, 3)
        preferences.autoNextChannel = false
        model.handleStall("No picture")
        await model.startPlayback(at: 4, resetStalls: false)
        model.handleStall("No picture")
        preferences.autoNextChannel = true
        await model.startPlayback(at: 0, resetStalls: false)

        XCTAssertEqual(model.failedResolutionIndices, [0, 1, 2])
        XCTAssertEqual(model.stalledIndices, [3, 4])
        XCTAssertNil(model.nextUntriedIndex(after: 2))
        XCTAssertEqual(model.retryActionTitle, "重试")
        XCTAssertTrue(model.errorMessage?.contains("2 条没有画面，3 条解析失败") == true)

        await model.startPlayback(at: 3)
        XCTAssertTrue(model.failedResolutionIndices.isEmpty)
        XCTAssertTrue(model.stalledIndices.isEmpty)
        XCTAssertEqual(model.playback?.index, 3)
    }

    func testExtractsIframeGeneratedByEncryptedPlayerScript() {
        let pageURL = URL(string: "http://play.example/play/kbs/?id=5")!
        let html = #"var encodedStr = "encrypted-payload";"#
        let playerScript = #"""
        document.getElementById("myElement").innerHTML =
          "<iframe src='https://cloud.example/player/paps.html?id=" + encodedStr + "'></iframe>";
        """#

        XCTAssertEqual(
            resolver.generatedIframeURL(
                in: html,
                playerScript: playerScript,
                pageURL: pageURL
            )?.absoluteString,
            "https://cloud.example/player/paps.html?id=encrypted-payload"
        )
    }

    func testEvaluatesEncryptedPlayerPageToHLSURL() {
        let pageURL = URL(string: "https://cloud.example/player/paps.html?id=payload")!
        let libraryScript = "var CryptoLibraryLoaded = true;"
        let pageScript = #"""
        var encryptedBase64Str = "payload";
        function decryptUrlWithExpiry(value) {
          return CryptoLibraryLoaded && value === "payload"
            ? "https://media.example/live/chinese-hd.m3u8?token=abc"
            : "";
        }
        """#

        XCTAssertEqual(
            resolver.evaluateEncryptedHLSURL(
                libraryScript: libraryScript,
                pageScript: pageScript,
                pageURL: pageURL
            )?.absoluteString,
            "https://media.example/live/chinese-hd.m3u8?token=abc"
        )
    }
}

private final class UnavailableStreamPage: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html>No stream</html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
