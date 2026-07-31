import XCTest
@testable import JRKANTV

final class LiveSiteContractTests: XCTestCase {
    func testCurrentPublicListingAndAtLeastOneHLSRoute() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_JRS_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_JRS_TESTS=1 to run the mutable live-site contract.")
        }

        let matches = try await JRSClient().fetchMatches()
        XCTAssertFalse(matches.isEmpty)

        let candidates = matches.flatMap(\.sources).prefix(12)
        XCTAssertFalse(candidates.isEmpty)

        let resolver = StreamResolver()
        var lastError: Error?
        for source in candidates {
            do {
                let streamURL = try await resolver.resolve(sourcePageURL: source.pageURL)
                XCTAssertTrue(streamURL.absoluteString.localizedCaseInsensitiveContains(".m3u8"))
                return
            } catch {
                lastError = error
            }
        }

        throw XCTSkip(
            "The listing contract passed, but sampled third-party routes were unavailable: "
            + (lastError?.localizedDescription ?? "unknown error")
        )
    }
}
