import Foundation

/// The real fixture behind a set of replays, for the statistics panel.
///
/// Replays only say who played and on which day; the statistics providers
/// match games by kickoff within half an hour. So the NBA game is looked up on
/// ESPN's scoreboard and used only when exactly one finished game has both
/// teams, started on that Beijing day (or the evening before, New York time)
/// and before the first upload. Anything less certain gives no statistics,
/// never a guessed time.
enum ReplayFixture {
    private struct Cached: Codable { let match: LiveMatch? }

    /// Cached: found for 30 days, not found for 6 hours (never after a network failure).
    static func nbaMatch(for videos: [ReplayVideo], session: URLSession = .shared, now: Date = Date()) async -> LiveMatch? {
        guard let first = videos.first, let matchup = first.matchup else { return nil }
        let teams = Set([matchup.left, matchup.right].map(MultiSportsClient.canonical))
        guard teams.isSubset(of: nbaTeams) else { return nil }
        let key = "fixture:\(matchup.key)@\(Int(first.gameDay.timeIntervalSince1970))"
        if let cached = ReplayCache.read(key, as: Cached.self) {
            let lifetime: TimeInterval = cached.value.match == nil ? 6 * 3600 : 30 * 86_400
            if now.timeIntervalSince(cached.savedAt) < lifetime { return cached.value.match }
        }
        let (match, complete) = await lookUp(videos, teams: teams, session: session)
        if match != nil || complete { ReplayCache.write(key, Cached(match: match)) }
        return match
    }

    private static func lookUp(_ videos: [ReplayVideo], teams: Set<String>, session: URLSession) async -> (LiveMatch?, complete: Bool) {
        guard let first = videos.first else { return (nil, false) }
        let earliestUpload = videos.map(\.postedAt).min() ?? first.postedAt
        let day = first.gameDay
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyyMMdd"
        // A Beijing morning game is the previous evening in New York.
        let dates = Set([day.addingTimeInterval(-86_400), day, day.addingTimeInterval(43_200)].map { formatter.string(from: $0) })
        // In parallel and short: this sits between the tap and the picture.
        let pages = await withTaskGroup(of: [(id: String, start: Date, home: String, away: String)]?.self) { group in
            for date in dates {
                group.addTask {
                    guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=\(date)") else { return nil }
                    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
                    guard let (data, response) = try? await session.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                    return events(root, teams: teams)
                }
            }
            var all: [[(id: String, start: Date, home: String, away: String)]?] = []
            for await rows in group { all.append(rows) }
            return all
        }
        let complete = pages.allSatisfy { $0 != nil }
        let found = pages.compactMap { $0 }.flatMap { $0 }
        var seen = Set<String>()
        let candidates = found.filter { seen.insert($0.id).inserted }.filter {
            ReplayParsing.beijingDay($0.start) == day && $0.start < earliestUpload
        }
        guard candidates.count == 1, let game = candidates.first else { return (nil, complete) }
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = MatchSchedule.feedTimeZone
        clock.dateFormat = "MM-dd HH:mm"
        return (LiveMatch(id: "replay-fixture:espn:\(game.id)", league: "NBA", time: clock.string(from: game.start),
                          homeTeam: game.home, awayTeam: game.away, homeLogoURL: nil, awayLogoURL: nil,
                          isHot: false, sources: []), true)
    }

    /// Finished games on one scoreboard page with exactly these two teams.
    static func events(_ root: [String: Any], teams: Set<String>) -> [(id: String, start: Date, home: String, away: String)] {
        let iso = ISO8601DateFormatter()
        return (root["events"] as? [[String: Any]] ?? []).compactMap { event in
            guard let comp = (event["competitions"] as? [[String: Any]])?.first,
                  let competitors = comp["competitors"] as? [[String: Any]], competitors.count == 2 else { return nil }
            func name(_ side: String) -> String? {
                competitors.first { MultiSportsClient.text($0["homeAway"]) == side }
                    .map { MultiSportsClient.canonical(MultiSportsClient.text(($0["team"] as? [String: Any])?["abbreviation"])) }
            }
            let status = ((comp["status"] as? [String: Any])?["type"] as? [String: Any]) ?? [:]
            let raw = MultiSportsClient.text(comp["date"])
            guard let home = name("home"), let away = name("away"), Set([home, away]) == teams,
                  (status["completed"] as? Bool) == true,
                  let start = iso.date(from: raw.replacingOccurrences(of: "Z", with: ":00Z")) ?? iso.date(from: raw) else { return nil }
            return (MultiSportsClient.text(event["id"]), start, home, away)
        }
    }

    static let nbaTeams: Set<String> = ["勇士", "湖人", "快船", "灰熊", "尼克斯", "鹈鹕", "马刺", "爵士", "奇才", "太阳", "老鹰", "凯尔特人",
        "篮网", "黄蜂", "公牛", "骑士", "独行侠", "掘金", "活塞", "火箭", "步行者", "热火", "雄鹿", "森林狼", "雷霆", "魔术", "76人",
        "开拓者", "国王", "猛龙"]
}
