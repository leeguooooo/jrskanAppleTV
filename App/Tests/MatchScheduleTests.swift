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
        XCTAssertEqual(MatchSchedule.status(for: "09-05 20:00", now: now), .live(elapsedMinutes: 30))
        XCTAssertEqual(MatchSchedule.status(for: "09-05 21:15", now: now), .upcoming(startsInMinutes: 45))
        XCTAssertEqual(MatchSchedule.status(for: "09-05 16:00", now: now), .finished)
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

    func testLiveWindowFollowsTheSport() {
        // A football match that kicked off 2h50m ago is over: the site has
        // already pulled its channels, so calling it live only leads the
        // viewer into five failing lines.
        // 2h20m after kickoff.
        let now = date("2026-09-05 22:50")
        XCTAssertEqual(MatchSchedule.status(for: "09-05 20:30", league: "美职联", now: now), .finished)
        // The same gap in basketball is still inside a long game.
        XCTAssertEqual(
            MatchSchedule.status(for: "09-05 20:30", league: "NBA", now: now),
            .live(elapsedMinutes: 140)
        )
        XCTAssertTrue(MatchSchedule.isBasketball(league: "菲MPBL"))
        XCTAssertFalse(MatchSchedule.isBasketball(league: "英超"))
    }
}
