import Foundation

/// A failed/empty provider never becomes a sticky preference. Every refresh starts
/// with Tencent; statistics and recent comments select their sources independently.
actor MultiSportsClient {
    private let tencent: TencentSportsClient
    private var miguIDs: [String: String] = [:]
    private var espnIDs: [String: String] = [:]
    private var verifiedTencent = Set<String>()
    private var catalogs: [String: (Date, [[String: Any]])] = [:]
    init(tencent: TencentSportsClient = TencentSportsClient()) { self.tencent = tencent }

    func statistics(match: LiveMatch, channels: [MatchSource], onPartial: (@Sendable (SportsSnapshot) async -> Void)? = nil) async throws -> SportsSnapshot {
        var values: [SportsSnapshot] = []
        if let mid = TencentSportsClient.candidateMID(match: match, channels: channels) {
            do {
                values.append(try await tencent.statistics(mid: mid, match: match))
                if let result = Self.select(values) {
                    await onPartial?(result)
                    if Self.complete(result) { return result }
                }
            } catch { try Task.checkCancellation() }
        }
        do {
            let id = try await miguID(match)
            let root = try await json("https://v0-sc.miguvideo.com/oes-sport-static/10/live/statistics/\(id)")
            values.append(try Self.miguStatistics(root, id: id, match: match))
            if let result = Self.select(values) {
                await onPartial?(result)
                if Self.complete(result) { return result }
            }
        } catch { try Task.checkCancellation() }
        do {
            let id = try await espnID(match)
            let root = try await json("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event=\(id)")
            values.append(try Self.espnStatistics(root, id: id, match: match))
        } catch { try Task.checkCancellation() }
        guard let value = Self.select(values) else { throw URLError(.resourceUnavailable) }
        return value
    }

    func comments(match: LiveMatch, channels: [MatchSource]) async throws -> [SportsComment] {
        if let mid = TencentSportsClient.candidateMID(match: match, channels: channels) {
            do {
                let verificationKey = key(match) + mid
                if !verifiedTencent.contains(verificationKey) {
                    try await tencent.verify(match: match, mid: mid)
                    if verifiedTencent.count > 20 { verifiedTencent.removeAll() }
                    verifiedTencent.insert(verificationKey)
                }
                let rows = try await tencent.comments(mid: mid)
                if !rows.isEmpty { return rows.map { SportsComment(id: "tencent:" + $0.id, text: $0.text, postedAt: $0.postedAt) } }
            } catch { try Task.checkCancellation() }
        }
        let id = try await miguID(match)
        let root = try await json("https://webapi.miguvideo.com/gateway/interaction/v2/comment/1/20/\(id)/40/NEW?clientType=1")
        return Self.miguComments(root, id: id)
    }

    static func complete(_ value: SportsSnapshot) -> Bool {
        value.periodTable != nil && value.comparisonTable != nil && value.playerTables.count == 2
    }
    /// Whole tables retain their provider. Never fill individual cells with a
    /// second provider's values or overwrite the preferred source's scoreboard.
    static func select(_ values: [SportsSnapshot]) -> SportsSnapshot? {
        guard let first = values.first else { return nil }
        var tables: [SportsTable] = []; var used = Set<String>(); var sources: [String] = [first.sourceName]
        for value in values {
            guard Set([value.left, value.right].map(canonical)) == Set([first.left, first.right].map(canonical)) else { continue }
            for original in value.tables {
                let kind = original.title == "分节得分" ? "period" : original.title == "球队技术统计" ? "comparison" : "player:" + canonical(original.title.components(separatedBy: " · ").first ?? original.title)
                guard original.rows.contains(where: { $0.dropFirst().contains { !$0.isEmpty && $0 != "—" } }), used.insert(kind).inserted else { continue }
                var table = original; table.sourceName = value.sourceName
                if canonical(value.left) != canonical(first.left) {
                    if kind == "comparison" { table = SportsTable(title: table.title, headers: ["项目", first.left, first.right], rows: table.rows.map { $0.count == 3 ? [$0[0], $0[2], $0[1]] : $0 }, sourceName: value.sourceName) }
                    if kind == "period" { table = SportsTable(title: table.title, headers: table.headers, rows: Array(table.rows.reversed()), sourceName: value.sourceName) }
                }
                tables.append(table)
                if !sources.contains(value.sourceName) { sources.append(value.sourceName) }
            }
        }
        return SportsSnapshot(mid: first.mid, left: first.left, right: first.right, score: first.score, period: first.period, tables: tables, updatedAt: first.updatedAt, leftBadge: first.leftBadge, rightBadge: first.rightBadge, sourceName: sources.joined(separator: " · "), scoreSourceName: first.sourceName)
    }
    private func key(_ match: LiveMatch) -> String { "\(match.league)|\(match.homeTeam)|\(match.awayTeam)|\(match.time)" }
    private func miguID(_ match: LiveMatch) async throws -> String {
        let key = key(match)
        if let id = miguIDs[key] { return id }
        guard ["NBA", "CBA"].contains(match.league.uppercased()) else { throw URLError(.resourceUnavailable) }
        let catalogKey = "migu:" + match.league.uppercased()
        let rows: [[String: Any]]
        if let cached = catalogs[catalogKey], Date().timeIntervalSince(cached.0) < 300 { rows = cached.1 }
        else {
            let page = match.league.uppercased() == "CBA" ? "494d21a4d6ee453b8b86bd3bb7658ed6" : "3cd6ba04967742879aaa40bee02a99a6"
            let html = try await bytes("https://www.miguvideo.com/p/home/\(page)")
            guard let text = String(data: html, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
            rows = Self.catalogRows(text)
            catalogs[catalogKey] = (Date(), rows)
        }
        let ids = Set(rows.compactMap { row -> String? in
            let teams = row["teams"] as? [[String: Any]] ?? []
            let names = teams.map { Self.text($0["teamName"]) }
            guard Self.text(row["competitionName"]).uppercased() == match.league.uppercased(),
                  Self.matches(names, start: Self.text(row["startTime"]), format: "yyyyMMddHHmm", match: match),
                  Self.text(row["pID"]).range(of: #"^[0-9]{12}$"#, options: .regularExpression) != nil else { return nil }
            return Self.text(row["pID"])
        })
        guard ids.count == 1, let id = ids.first else { throw URLError(.cannotParseResponse) }
        // The public schedule binds ID, competition, both teams and tipoff.
        if miguIDs.count > 20 { miguIDs.removeAll() }
        miguIDs[key] = id
        return id
    }
    private func espnID(_ match: LiveMatch) async throws -> String {
        let key = key(match)
        if let id = espnIDs[key] { return id }
        guard match.league.uppercased() == "NBA", let kickoff = MatchSchedule.kickoff(from: match.time) else { throw URLError(.resourceUnavailable) }
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "America/New_York"); f.dateFormat = "yyyyMMdd"
        let date = f.string(from: kickoff)
        let root = try await json("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=\(date)")
        let ids = Set((root["events"] as? [[String: Any]] ?? []).compactMap { row -> String? in
            guard let comp = (row["competitions"] as? [[String: Any]])?.first,
                  Self.espnMatch(comp, match: match) else { return nil }
            let id = Self.text(row["id"])
            return id.range(of: #"^[0-9]+$"#, options: .regularExpression) == nil ? nil : id
        })
        guard ids.count == 1, let id = ids.first else { throw URLError(.cannotParseResponse) }
        if espnIDs.count > 20 { espnIDs.removeAll() }; espnIDs[key] = id
        return id
    }
    private func bytes(_ url: String) async throws -> Data {
        guard let url = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(JRSClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await tencent.session.data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count <= 4_000_000 else { throw URLError(.badServerResponse) }
        return bytes
    }
    private func json(_ url: String) async throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: await bytes(url)) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return root
    }

    static func text(_ v: Any?, missing: String = "") -> String {
        if let s = v as? String, !s.isEmpty { return s }
        if let n = v as? NSNumber { return n.stringValue }; return missing
    }
    static func canonical(_ name: String) -> String {
        let aliases = ["GS":"勇士", "GSW":"勇士", "LAL":"湖人", "LAC":"快船", "MEM":"灰熊", "NY":"尼克斯", "NYK":"尼克斯", "NO":"鹈鹕", "NOP":"鹈鹕", "SA":"马刺", "SAS":"马刺", "UTAH":"爵士", "UTA":"爵士", "WSH":"奇才", "WAS":"奇才", "PHO":"太阳", "PHX":"太阳", "ATL":"老鹰", "BOS":"凯尔特人", "BKN":"篮网", "CHA":"黄蜂", "CHI":"公牛", "CLE":"骑士", "DAL":"独行侠", "DEN":"掘金", "DET":"活塞", "HOU":"火箭", "IND":"步行者", "MIA":"热火", "MIL":"雄鹿", "MIN":"森林狼", "OKC":"雷霆", "ORL":"魔术", "PHI":"76人", "POR":"开拓者", "SAC":"国王", "TOR":"猛龙", "布鲁克林篮网":"篮网", "金州勇士":"勇士", "洛杉矶湖人":"湖人", "洛杉矶快船":"快船", "灰熊队":"灰熊"]
        return aliases[name.uppercased()] ?? aliases[name] ?? name
    }
    static func matches(_ names: [String], start: String, format: String, match: LiveMatch, now: Date = Date()) -> Bool {
        guard names.count == 2, Set(names.map(canonical)) == Set([match.homeTeam, match.awayTeam].map(canonical)), let kickoff = MatchSchedule.kickoff(from: match.time, now: now) else { return false }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = format
        guard let date = f.date(from: start) else { return false }
        return abs(date.timeIntervalSince(kickoff)) <= 1800
    }
    static func catalogRows(_ html: String) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        func walk(_ value: Any) {
            if let obj = value as? [String: Any] {
                if obj["teams"] is [[String: Any]], obj["pID"] != nil { rows.append(obj) }
                for child in obj.values { walk(child) }
            } else if let values = value as? [Any] { values.forEach(walk) }
        }
        for marker in ["__INITIAL_GROUPS_STATE__", "__INITIAL_COMPS_STATE__"] {
            guard let markerRange = html.range(of: "window." + marker), let brace = html[markerRange.upperBound...].firstIndex(of: "{") else { continue }
            var depth = 0; var quoted = false; var escaped = false
            for i in html[brace...].indices {
                let c = html[i]
                if quoted { if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false } }
                else if c == "\"" { quoted = true }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 {
                    if let bytes = String(html[brace...i]).data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: bytes) { walk(root) }
                    break
                } }
            }
        }
        return rows
    }

    static func miguStatistics(_ root: [String: Any], id: String, match: LiveMatch, now: Date = Date()) throws -> SportsSnapshot {
        guard text(root["code"]) == "200", let bkb = root["BKB"] as? [String: Any], let data = bkb["matchData"] as? [String: Any], let teams = data["matchTeam"] as? [String: Any], let home = teams["home"] as? [String: Any], let away = teams["guest"] as? [String: Any], matches([text(home["teamName"]), text(away["teamName"])], start: text(data["matchDatetime"]), format: "yyyy-MM-dd HH:mm:ss", match: match, now: now), text(data["competitionShortName"]).uppercased() == match.league.uppercased() else { throw URLError(.cannotParseResponse) }
        let names = [text(home["teamName"]), text(away["teamName"])]
        var tables: [SportsTable] = []
        let quarters = data["quarters"] as? [[String: Any]] ?? []
        if !quarters.isEmpty { tables.append(SportsTable(title: "分节得分", headers: ["球队"] + quarters.map { "第\(text($0["quarter"]))节" }, rows: [ [names[0]] + quarters.map { text($0["homeScore"], missing: "—") }, [names[1]] + quarters.map { text($0["visitingScore"], missing: "—") } ])) }
        let columns = [("points", "得分"), ("rebounds", "篮板"), ("assists", "助攻"), ("steals", "抢断"), ("blocks", "盖帽"), ("turnovers", "失误"), ("fieldGoalsPercentage", "投篮命中率"), ("threePointPercentage", "三分命中率"), ("trueShootingPct", "真实命中率")]
        func stat(_ obj: [String: Any], _ key: String) -> String {
            let field = obj[key] as? [String: Any] ?? [:]
            let value = text(field["value"], missing: "—")
            return value != "—" && text(field["hasPercentType"]) == "1" ? value + "%" : value
        }
        let hs = home["matchTeamStat"] as? [String: Any] ?? [:], aws = away["matchTeamStat"] as? [String: Any] ?? [:]
        let comparisons = columns.map { [$0.1, stat(hs, $0.0), stat(aws, $0.0)] }.filter { $0[1] != "—" || $0[2] != "—" }
        if !comparisons.isEmpty { tables.append(SportsTable(title: "球队技术统计", headers: ["项目"] + names, rows: comparisons)) }
        let players = bkb["matchPlayerStatBeanList"] as? [[String: Any]] ?? []
        let fields = ["seconds", "points", "rebounds", "assists", "steals", "blocks", "turnovers", "plusMinus", "trueShootingPct"]
        for (team, name) in zip([home, away], names) {
            let teamID = text(team["wcTeamId"])
            let rows = players.filter { !teamID.isEmpty && text($0["wcTeamId"]) == teamID }.map { p -> [String] in
                [text(p["nickName"], missing: "—")] + fields.map { key in
                    if key == "seconds", let seconds = Int(stat(p, key)) { return "\(seconds / 60):\(String(format: "%02d", seconds % 60))" }
                    return stat(p, key)
                }
            }
            if !rows.isEmpty { tables.append(SportsTable(title: "\(name) · 球员技术统计", headers: ["球员", "时间", "得分", "篮板", "助攻", "抢断", "盖帽", "失误", "+/-", "真实命中率"], rows: rows)) }
        }
        return SportsSnapshot(mid: "migu:\(id)", left: names[0], right: names[1], score: "\(text(home["teamScore"], missing: "—")) : \(text(away["teamScore"], missing: "—"))", period: "", tables: tables, updatedAt: now, leftBadge: URL(string: text(home["teamLogo"])), rightBadge: URL(string: text(away["teamLogo"])), sourceName: "咪咕视频")
    }
    static func miguComments(_ root: [String: Any], id: String, now: Date = Date()) -> [SportsComment] {
        guard text(root["code"]) == "200" else { return [] }
        let body = root["body"] as? [String: Any] ?? [:]
        var seen = Set<String>()
        return (body["commentInfoList"] as? [[String: Any]] ?? []).compactMap { row -> SportsComment? in
            let cid = text(row["commentId"])
            guard text(row["contentId"]) == id, text(row["objectId"]) == id, (row["top"] as? Bool) != true, !cid.isEmpty, seen.insert(cid).inserted, let stamp = Double(text(row["createTime"])) else { return nil }
            let posted = Date(timeIntervalSince1970: stamp / 1000)
            guard now.timeIntervalSince(posted) < 120, posted.timeIntervalSince(now) < 30 else { return nil }
            let value = text(row["body"]).replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression).components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.contains("观赛群"), !value.contains("扫码"), !value.contains("http") else { return nil }
            return SportsComment(id: "migu:" + cid, text: String(value.prefix(80)), postedAt: posted)
        }.sorted { $0.postedAt < $1.postedAt }
    }
    static func espnMatch(_ comp: [String: Any], match: LiveMatch, now: Date = Date()) -> Bool {
        let teams = comp["competitors"] as? [[String: Any]] ?? []
        let names = teams.map { canonical(text(($0["team"] as? [String: Any])?["abbreviation"])) }
        guard teams.count == 2, Set(names) == Set([match.homeTeam, match.awayTeam].map(canonical)), let kickoff = MatchSchedule.kickoff(from: match.time, now: now) else { return false }
        guard let start = ISO8601DateFormatter().date(from: text(comp["date"]).replacingOccurrences(of: "Z", with: ":00Z")) ?? ISO8601DateFormatter().date(from: text(comp["date"])) else { return false }
        return abs(start.timeIntervalSince(kickoff)) <= 1800
    }
    static func espnStatistics(_ root: [String: Any], id: String, match: LiveMatch, now: Date = Date()) throws -> SportsSnapshot {
        guard match.league.uppercased() == "NBA", let header = root["header"] as? [String: Any], text(header["id"]) == id, let comp = (header["competitions"] as? [[String: Any]])?.first, espnMatch(comp, match: match, now: now), let box = root["boxscore"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
        let competitors = comp["competitors"] as? [[String: Any]] ?? []
        let home = competitors.first { text($0["homeAway"]) == "home" } ?? [:], away = competitors.first { text($0["homeAway"]) == "away" } ?? [:]
        let teams = [home, away]; let names = teams.map { canonical(text(($0["team"] as? [String: Any])?["abbreviation"])) }
        var tables: [SportsTable] = []
        let periods = teams.map { $0["linescores"] as? [[String: Any]] ?? [] }
        if let count = periods.map({ $0.count }).max(), count > 0 { tables.append(SportsTable(title: "分节得分", headers: ["球队"] + (1...count).map { "第\($0)节" }, rows: zip(names, periods).map { name, row in [name] + (0..<count).map { $0 < row.count ? text(row[$0]["displayValue"], missing: "—") : "—" } })) }
        let boxes = box["teams"] as? [[String: Any]] ?? []
        let ordered = teams.map { team in boxes.first { text(($0["team"] as? [String: Any])?["id"]) == text(team["id"]) } ?? [:] }
        let labels = ["rebounds":"篮板", "assists":"助攻", "steals":"抢断", "blocks":"盖帽", "turnovers":"失误", "fieldGoalPct":"投篮命中率", "threePointFieldGoalPct":"三分命中率", "freeThrowPct":"罚球命中率"]
        let teamRows = labels.keys.sorted().map { key -> [String] in
            [labels[key]!] + ordered.map { obj in text((obj["statistics"] as? [[String: Any]] ?? []).first { text($0["name"]) == key }?["displayValue"], missing: "—") }
        }.filter { $0[1] != "—" || $0[2] != "—" }
        if !teamRows.isEmpty { tables.append(SportsTable(title: "球队技术统计", headers: ["项目"] + names, rows: teamRows)) }
        for team in box["players"] as? [[String: Any]] ?? [] {
            let name = canonical(text((team["team"] as? [String: Any])?["abbreviation"]))
            guard names.contains(name), let group = (team["statistics"] as? [[String: Any]])?.first, let labels = group["labels"] as? [String] else { continue }
            let translations = ["MIN":"时间", "PTS":"得分", "REB":"篮板", "AST":"助攻", "STL":"抢断", "BLK":"盖帽", "TO":"失误", "PF":"犯规", "FG":"投篮", "3PT":"三分", "FT":"罚球", "OREB":"前板", "DREB":"后板"]
            let rows = (group["athletes"] as? [[String: Any]] ?? []).compactMap { row -> [String]? in
                guard let values = row["stats"] as? [String], values.count == labels.count else { return nil }
                return [text((row["athlete"] as? [String: Any])?["displayName"], missing: "—")] + values.map { $0.isEmpty ? "—" : $0 }
            }
            if !rows.isEmpty { tables.append(SportsTable(title: "\(name) · 球员技术统计", headers: ["球员"] + labels.map { translations[$0] ?? $0 }, rows: rows)) }
        }
        let status = (comp["status"] as? [String: Any])?["type"] as? [String: Any] ?? [:]
        return SportsSnapshot(mid: "espn:\(id)", left: names[0], right: names[1], score: "\(text(home["score"], missing: "—")) : \(text(away["score"], missing: "—"))", period: text(status["shortDetail"]), tables: tables, updatedAt: now, sourceName: "ESPN")
    }
}
