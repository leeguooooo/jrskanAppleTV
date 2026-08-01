import XCTest
@testable import JRKANTV

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
