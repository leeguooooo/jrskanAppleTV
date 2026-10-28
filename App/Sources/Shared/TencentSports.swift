import Combine
import Foundation

struct SportsComment: Identifiable, Equatable {
    let id: String
    let text: String
    let postedAt: Date
}

struct SportsTable: Equatable {
    let title: String
    let headers: [String]
    let rows: [[String]]
    var sourceName: String = ""
}

struct SportsSnapshot {
    let mid: String
    let left: String
    let right: String
    let score: String
    let period: String
    let tables: [SportsTable]
    let updatedAt: Date
    var leftBadge: URL? = nil
    var rightBadge: URL? = nil
    var sourceName: String = "腾讯体育"
    var scoreSourceName: String? = nil

    var periodTable: SportsTable? { tables.first { $0.title == "分节得分" } }
    var comparisonTable: SportsTable? { tables.first { $0.title == "球队技术统计" } }
    var playerTables: [SportsTable] { tables.filter { $0.title.hasSuffix("球员技术统计") } }
}

/// Public read-only endpoints. An ephemeral session keeps this separate from
/// playback, cookies and account login. No provider token or write API is used.
struct TencentSportsClient {
    let session: URLSession

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        self.session = session ?? URLSession(configuration: config)
    }

    static func candidateMID(match: LiveMatch, channels: [MatchSource]) -> String? {
        // The source exposes Tencent's event ID. Do not guess a competition
        // for unrelated leagues or match names with a fuzzy substring search.
        let competition: String
        switch match.league.uppercased() {
        case "NBA": competition = "100000"
        case "CBA": competition = "100008"
        default: return nil
        }
        let ids = Set(channels.compactMap { source -> String? in
            guard ["kbs", "vxt", "txf"].contains(source.pageURL.path.split(separator: "/").last.map(String.init) ?? ""),
                  let value = URLComponents(url: source.pageURL, resolvingAgainstBaseURL: true)?
                    .queryItems?.first(where: { $0.name == "id" })?.value,
                  value.range(of: #"^[0-9]{10,12}$"#, options: .regularExpression) != nil else { return nil }
            return value
        })
        guard ids.count == 1, let id = ids.first else { return nil }
        return "\(competition):\(id)"
    }

    static func matches(_ info: [String: Any], match: LiveMatch, mid: String, now: Date = Date()) -> Bool {
        guard text(info["mid"]) == mid,
              Set([text(info["leftName"]), text(info["rightName"])].map(MultiSportsClient.canonical)) == Set([match.homeTeam, match.awayTeam].map(MultiSportsClient.canonical)),
              let kickoff = MatchSchedule.kickoff(from: match.time, now: now) else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let start = formatter.date(from: text(info["startTime"])) else { return false }
        return abs(start.timeIntervalSince(kickoff)) <= 30 * 60
    }

    func verify(match: LiveMatch, mid: String) async throws {
        let data = try await get(host: "matchweb.sports.qq.com", path: "/kbs/matchDetail", query: ["mid": mid])
        guard let info = data["matchInfo"] as? [String: Any], Self.matches(info, match: match, mid: mid) else {
            throw URLError(.cannotParseResponse)
        }
    }

    func statistics(mid: String, match: LiveMatch) async throws -> SportsSnapshot {
        let data = try await get(host: "matchweb.sports.qq.com", path: "/kbs/matchStat", query: ["mid": mid])
        guard var info = data["teamInfo"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
        info["mid"] = mid
        guard Self.matches(info, match: match, mid: mid) else { throw URLError(.cannotParseResponse) }
        return try Self.parseStatistics(data, mid: mid)
    }

    static func parseStatistics(_ data: [String: Any], mid: String, now: Date = Date()) throws -> SportsSnapshot {
        guard let info = data["teamInfo"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
        let left = text(info["leftName"]), right = text(info["rightName"])
        guard !left.isEmpty, !right.isEmpty else { throw URLError(.cannotParseResponse) }
        var tables: [SportsTable] = []
        if let periods = data["periodGoals"] as? [String: Any],
           let headers = periods["head"] as? [String], let rows = periods["rows"] as? [[String]], rows.count == 2 {
            tables.append(SportsTable(title: "分节得分", headers: ["球队"] + headers,
                rows: zip([left, right], rows).map { [$0.0] + Array($0.1.dropFirst()) }))
        }
        let teamRows = (data["teamStats"] as? [[String: Any]] ?? []).compactMap { stat -> [String]? in
            let label = text(stat["text"])
            guard !label.isEmpty else { return nil }
            func value(_ side: String) -> String {
                let base = text(stat[side + "Val"], missing: "—")
                let extra = text(stat[side + "Ext"])
                return extra.isEmpty ? base : "\(base) (\(extra))"
            }
            return [label, value("left"), value("right")]
        }
        if !teamRows.isEmpty { tables.append(SportsTable(title: "球队技术统计", headers: ["项目", left, right], rows: teamRows)) }
        if let players = data["playerStats"] as? [String: Any] {
            for (side, name) in [("left", left), ("right", right)] {
                let entries = players[side] as? [[String: Any]] ?? []
                guard let headers = entries.first?["head"] as? [String], !headers.isEmpty else { continue }
                let rows = entries.compactMap { entry -> [String]? in
                    guard let row = entry["row"] as? [String], row.count == headers.count + 1 else { return nil }
                    return [[row[0], row[1]].filter { !$0.isEmpty }.joined(separator: " ")] + Array(row.dropFirst(2))
                }
                if !rows.isEmpty { tables.append(SportsTable(title: "\(name) · 球员技术统计", headers: headers, rows: rows)) }
            }
        }
        return SportsSnapshot(mid: mid, left: left, right: right,
            score: "\(text(info["leftGoal"], missing: "—")) : \(text(info["rightGoal"], missing: "—"))",
            period: text(info["quarterDesc"]), tables: tables, updatedAt: now,
            leftBadge: URL(string: text(info["leftBadge"])), rightBadge: URL(string: text(info["rightBadge"])))
    }

    func comments(mid: String) async throws -> [SportsComment] {
        let data = try await get(host: "app.sports.qq.com", path: "/dmComment/liveList",
                                 query: ["mid": mid, "topN": "20", "commentId": "0"])
        return Self.parseComments(data, mid: mid)
    }

    static func parseComments(_ data: [String: Any], mid: String, now: Date = Date()) -> [SportsComment] {
        var seen = Set<String>()
        return (data["list"] as? [[String: Any]] ?? []).compactMap { row -> SportsComment? in
            let id = text(row["commentId"])
            guard text(row["mid"]) == mid, text(row["type"]) == "0", !id.isEmpty,
                  seen.insert(id).inserted, let stamp = Double(text(row["postTime"])) else { return nil }
            let date = Date(timeIntervalSince1970: stamp)
            guard now.timeIntervalSince(date) < 120, date.timeIntervalSince(now) < 30 else { return nil }
            let message = text(row["content"])
                .replacingOccurrences(of: #"\[[^\]]{1,30}/\]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
                .components(separatedBy: .controlCharacters).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return nil }
            return SportsComment(id: id, text: String(message.prefix(80)), postedAt: date)
        }.sorted { $0.postedAt < $1.postedAt }
    }

    private func get(host: String, path: String, query: [String: String]) async throws -> [String: Any] {
        var components = URLComponents()
        components.scheme = "https"; components.host = host; components.path = path
        var parameters = query
        parameters["_t"] = String(Int(Date().timeIntervalSince1970 * 1_000))
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(JRSClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://sports.qq.com/", forHTTPHeaderField: "Referer")
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, bytes.count <= 2_000_000,
              let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              (json["code"] as? Int) == 0, let data = json["data"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return data
    }

    private static func text(_ value: Any?, missing: String = "") -> String {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return missing
    }
}

@MainActor
final class MatchInsightsModel: ObservableObject {
    @Published private(set) var mid: String?
    @Published private(set) var snapshot: SportsSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var status = "正在匹配本场比赛…"
    @Published private(set) var comments: [SportsComment] = []
    @Published var danmakuEnabled = true
    private let client: MultiSportsClient
    private var seen: [String] = []
    private var context: (LiveMatch, [MatchSource])?
    private var generation = 0

    init(client: TencentSportsClient = TencentSportsClient()) { self.client = MultiSportsClient(tencent: client) }

    func watch(match: LiveMatch, channels: [MatchSource]) async {
        generation += 1
        let current = generation
        isRefreshing = false
        guard ["NBA", "CBA"].contains(match.league.uppercased()) else {
            context = nil; mid = nil; snapshot = nil; comments = []; status = "暂无可匹配的本场数据"; return
        }
        let channelKey = channels.map { $0.pageURL.absoluteString }.sorted().joined(separator: ",")
        let key = "\(match.id)|\(match.homeTeam)|\(match.awayTeam)|\(match.time)|\(channelKey)"
        if mid != key { snapshot = nil; comments = []; seen = [] }
        context = (match, channels)
        mid = key
        status = snapshot == nil ? "正在加载比赛数据…" : ""
        while !Task.isCancelled, current == generation {
            let started = ContinuousClock.now
            await refresh()
            // Count network/fallback time toward the interval; never overlap requests
            // or replay missed ticks after a slow provider.
            let pause = max(Duration.seconds(1), .seconds(10) - started.duration(to: .now))
            do { try await Task.sleep(for: pause) } catch { return }
        }
    }

    /// Opening the panel and manual refresh share the poll's request guard.
    /// Keep the last snapshot visible while fetching; never queue duplicate requests.
    func refresh() async {
        guard !Task.isCancelled, !isRefreshing, let context, mid != nil else { return }
        let current = generation
        isRefreshing = true
        if snapshot == nil { status = "正在加载比赛数据…" }
        defer { if current == generation { isRefreshing = false } }
        do {
            let value = try await client.statistics(match: context.0, channels: context.1) { [weak self] partial in
                await self?.accept(partial, generation: current)
            }
            try Task.checkCancellation()
            guard current == generation else { return }
            snapshot = value; status = ""
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            status = snapshot == nil ? "各数据源暂未提供本场统计，稍后自动重试" : "数据更新暂时中断，显示上次结果"
        }
    }

    private func accept(_ value: SportsSnapshot, generation: Int) {
        guard !Task.isCancelled, generation == self.generation else { return }
        snapshot = value; status = ""
    }

    func watchComments() async {
        comments = []
        guard danmakuEnabled, let key = mid, let context else { return }
        while !Task.isCancelled, danmakuEnabled, mid == key {
            do {
                let batch = try await client.comments(match: context.0, channels: context.1, excluding: Set(seen))
                try Task.checkCancellation()
                guard danmakuEnabled, mid == key else { return }
                for comment in batch where !seen.contains(comment.id) {
                    comments.append(comment); seen.append(comment.id)
                }
                comments = Array(comments.filter { Date().timeIntervalSince($0.postedAt) < 120 }.suffix(24))
                seen = Array(seen.suffix(500))
            } catch { if Task.isCancelled { return } }
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
        }
    }
}
