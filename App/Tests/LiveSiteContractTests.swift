import XCTest
#if os(tvOS)
@testable import JRKANTV
#else
@testable import JRKANiOS
#endif

final class LiveSiteContractTests: XCTestCase {
    func testWebsiteEventStatusContract() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_JRS_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_JRS_TESTS=1 to check the website event feed.")
        }
        let matches = try await JRSClient().fetchMatches()
        let supported = matches.filter {
            let ids = $0.id.split(separator: ",")
            return ids.count == 3 && (ids[1] == "1" || ids[1] == "2")
        }
        XCTAssertFalse(supported.isEmpty, "Expected football/basketball fixtures from the website.")
        XCTAssertTrue(supported.allSatisfy { $0.providerState != nil },
            "The event configuration, transport encoding or table schema changed; schedule-only fallback is active.")
        XCTAssertTrue(supported.allSatisfy { $0.providerState?.status(now: Date()) != nil },
            "The event feed contains an unsupported or stale match state.")
    }

    func testCurrentPublicListingAndAtLeastOneHLSRoute() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_JRS_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_JRS_TESTS=1 to run the mutable live-site contract.")
        }

        let matches = try await JRSClient().fetchMatches()
        XCTAssertFalse(matches.isEmpty)

        let liveMatches = matches.filter { MatchSchedule.status(for: $0).isLive }
        let candidates = (liveMatches.isEmpty ? matches : liveMatches).flatMap(\.sources).prefix(12)
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

        XCTFail(
            "No sampled route returned a valid HLS playlist: "
            + (lastError?.localizedDescription ?? "unknown error")
        )
    }
}
