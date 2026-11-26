import Foundation

// Full-game recordings that fans upload to Weibo after a match: whole games,
// halves and single quarters, usually titled "11月26日…NBA杯 热火vs76人全场回放".
// This file only parses and classifies; WeiboClient fetches.

/// One Weibo video post that looks like a match recording.
struct ReplayVideo: Identifiable, Hashable, Sendable {
    enum Part: Hashable, Sendable {
        case full
        case firstHalf
        case secondHalf
        case period(Int)
        case other

        var label: String {
            switch self {
            case .full: return "全场"
            case .firstHalf: return "上半场"
            case .secondHalf: return "下半场"
            case .period(let n): return "第\(ReplayVideo.chineseDigits[n] ?? String(n))节"
            case .other: return "片段"
            }
        }

        /// Display order inside one game: whole game, halves, quarters, the rest.
        var order: Int {
            switch self {
            case .full: return 0
            case .firstHalf: return 1
            case .secondHalf: return 2
            case .period(let n): return 2 + n
            case .other: return 100
            }
        }
    }

    struct Matchup: Hashable, Sendable {
        let left: String
        let right: String

        /// Order-free key in canonical team names: "热火vs76人" and "76人vs热火"
        /// are the same game.
        var key: String {
            [MultiSportsClient.canonical(left), MultiSportsClient.canonical(right)].sorted().joined(separator: "|")
        }
    }

    /// Weibo's short id (mblogid / bid), used to fetch fresh play links.
    let id: String
    let author: String
    let authorID: String
    let postedAt: Date
    /// Plain text of the post, links and "某某的微博视频" removed.
    let text: String
    let duration: TimeInterval
    let coverURL: URL?
    let matchup: Matchup?
    let part: Part
    /// Match day named in the title ("11月26日"), Beijing midnight.
    let titledDay: Date?

    /// The day the game belongs to: the title's date, else the posting day.
    var gameDay: Date { titledDay ?? ReplayParsing.beijingDay(postedAt) }

    /// The post text without hashtags, for a one-line title.
    var title: String {
        let stripped = text.replacingOccurrences(of: #"#[^#]{1,40}#"#, with: " ", options: .regularExpression)
        return ReplayParsing.collapse(stripped)
    }

    fileprivate static let chineseDigits = [1: "一", 2: "二", 3: "三", 4: "四"]

    /// The post on Weibo, for 分享 (it opens in the Weibo app or the browser).
    var shareURL: URL {
        URL(string: authorID.isEmpty ? "https://m.weibo.cn/status/\(id)" : "https://weibo.com/\(authorID)/\(id)")!
    }

    /// "热火 vs 76人 · 全场"
    var displayTitle: String {
        guard let matchup else { return title }
        return "\(matchup.left) vs \(matchup.right) · \(part.label)"
    }
}

/// Where each recording was left off, so a three-hour game picks up again.
/// Kept for 30 days; finished or barely started ones are not kept.
enum ReplayResume {
    private static let key = "replayPositions"
    private static let lifetime: TimeInterval = 30 * 86_400

    static func position(for id: String, store: UserDefaults = .standard) -> Double? {
        guard let entry = (store.dictionary(forKey: key) as? [String: [Double]])?[id], entry.count == 2,
              Date().timeIntervalSince1970 - entry[1] < lifetime else { return nil }
        return entry[0]
    }

    static func save(_ seconds: Double, duration: Double?, for id: String, store: UserDefaults = .standard) {
        var all = (store.dictionary(forKey: key) as? [String: [Double]]) ?? [:]
        let now = Date().timeIntervalSince1970
        all = all.filter { now - ($0.value.last ?? 0) < lifetime }
        if seconds < 30 || (duration.map { $0.isFinite && $0 > 0 && seconds > $0 - 60 } ?? false) {
            all[id] = nil
        } else {
            all[id] = [seconds, now]
        }
        store.set(all, forKey: key)
    }
}

/// Videos of one game from one or more uploaders.
struct ReplayGroup: Identifiable, Hashable, Sendable {
    let matchup: ReplayVideo.Matchup
    let day: Date
    let videos: [ReplayVideo]

    var id: String { "\(matchup.key)@\(Int(day.timeIntervalSince1970))" }
    var title: String { "\(matchup.left) vs \(matchup.right)" }
    var hasFullGame: Bool { videos.contains { $0.part == .full } }
    var latestPost: Date { videos.map(\.postedAt).max() ?? day }
}

/// Remote-config knobs, see AppConfig.Replay.
struct ReplayRules: Equatable, Sendable {
    var minDuration: TimeInterval = 600
    var fullDuration: TimeInterval = 5400
    var windowHours: Double = 48
}

enum ReplayParsing {
    static let beijing = TimeZone(identifier: "Asia/Shanghai")!

    private static let weiboDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter
    }()

    /// "Thu Nov 26 09:05:37 +0800 2026"; nil for anything else.
    static func date(_ raw: Any?) -> Date? {
        guard let raw = raw as? String else { return nil }
        return weiboDate.date(from: raw)
    }

    static func beijingDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijing
        return calendar.startOfDay(for: date)
    }

    static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// m.weibo.cn sends HTML; weibo.com sends text_raw. Both end up as plain
    /// text with the t.cn link and the "某某的微博视频" link label removed.
    static func plainText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: .regularExpression)
        // The video link's label is a span inside an anchor; drop the whole anchor.
        text = text.replacingOccurrences(of: #"<a[^>]*>(?:(?!</a>).)*?的微博视频(?:(?!</a>).)*?</a>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = text.replacingOccurrences(of: #"https?://t\.cn/\S+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\S{1,30}的微博视频"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\u{200B}", with: "")
        return collapse(text)
    }

    // MARK: Classification

    private static let suffixWords = ["全场", "上半场", "下半场", "第", "录像", "回放", "高清", "中文", "英文", "比赛", "集锦", "精彩", "加时", "完整", "超清", "国语", "粤语", "解说"]
    private static let prefixBreaks = CharacterSet(charactersIn: "杯赛季日：:】」|｜")

    /// "nba杯东部小组赛：热火vs76人 第二节回放" → 热火 / 76人.
    static func matchup(in text: String) -> ReplayVideo.Matchup? {
        let cleaned = text.replacingOccurrences(of: "#", with: " ")
        let pattern = #"([\p{Han}A-Za-z0-9·]{1,16})\s*(?:vs|VS|Vs|vS|V\.S\.|对阵)\s*([\p{Han}A-Za-z0-9·]{1,16})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let leftRange = Range(found.range(at: 1), in: cleaned),
              let rightRange = Range(found.range(at: 2), in: cleaned) else { return nil }
        var left = String(cleaned[leftRange])
        if let last = left.components(separatedBy: prefixBreaks).last { left = last }
        // "2026-2027赛季NBA杯热火" has no break before the team; English
        // league prefixes are the usual culprit.
        left = left.replacingOccurrences(of: #"^(?:NBA|nba|CBA|cba|WNBA)"#, with: "", options: .regularExpression)
        var right = String(cleaned[rightRange])
        for word in suffixWords {
            if let range = right.range(of: word), range.lowerBound != right.startIndex {
                right = String(right[..<range.lowerBound])
            }
        }
        left = left.trimmingCharacters(in: .whitespaces)
        right = right.trimmingCharacters(in: .whitespaces)
        guard (1...10).contains(left.count), (1...10).contains(right.count), left != right,
              !left.allSatisfy(\.isNumber), !right.allSatisfy(\.isNumber) else { return nil }
        return ReplayVideo.Matchup(left: left, right: right)
    }

    static func part(of text: String, duration: TimeInterval, rules: ReplayRules) -> ReplayVideo.Part {
        if text.contains("上半场") { return .firstHalf }
        if text.contains("下半场") { return .secondHalf }
        if let regex = try? NSRegularExpression(pattern: #"第\s*([一二三四1-4])\s*节"#),
           let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(found.range(at: 1), in: text) {
            let digit = String(text[range])
            let n = Int(digit) ?? ["一": 1, "二": 2, "三": 3, "四": 4][digit] ?? 0
            if n > 0 { return .period(n) }
        }
        if text.contains("全场") || duration >= rules.fullDuration { return .full }
        return .other
    }

    /// "11月26日" in the title, put in the year that keeps it at or just
    /// before the posting time (a December game posted in January).
    static func titledDay(in text: String, postedAt: Date) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2})月(\d{1,2})日"#),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let monthRange = Range(found.range(at: 1), in: text),
              let dayRange = Range(found.range(at: 2), in: text),
              let month = Int(text[monthRange]), let day = Int(text[dayRange]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijing
        let year = calendar.component(.year, from: postedAt)
        guard var date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        if date.timeIntervalSince(postedAt) > 2 * 86_400,
           let previous = calendar.date(byAdding: .year, value: -1, to: date) {
            date = previous
        }
        return date
    }

    /// A recording worth listing: a video long enough not to be a highlight,
    /// naming two teams, and either labelled as a replay or game-length.
    static func video(id: String, author: String, authorID: String, postedAt: Date, rawText: String,
                      duration: TimeInterval, coverURL: URL?, rules: ReplayRules) -> ReplayVideo? {
        let text = plainText(rawText)
        guard duration >= rules.minDuration, let matchup = matchup(in: text) else { return nil }
        let labelled = ["回放", "录像", "全场", "半场", "节"].contains { text.contains($0) }
        guard labelled || duration >= rules.fullDuration else { return nil }
        if ["集锦", "盘点", "十佳", "五佳"].contains(where: { text.contains($0) }) { return nil }
        return ReplayVideo(id: id, author: author, authorID: authorID, postedAt: postedAt, text: text,
                           duration: duration, coverURL: coverURL, matchup: matchup,
                           part: part(of: text, duration: duration, rules: rules),
                           titledDay: titledDay(in: text, postedAt: postedAt))
    }

    // MARK: Response shapes

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private static func https(_ raw: String?) -> URL? {
        guard var raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") { raw = "https://" + raw.dropFirst("http://".count) }
        if raw.hasPrefix("//") { raw = "https:" + raw }
        return URL(string: raw)
    }

    /// One status from weibo.com/ajax (profile waterfall, statuses/show).
    static func comVideo(_ status: [String: Any], rules: ReplayRules) -> ReplayVideo? {
        guard let page = status["page_info"] as? [String: Any],
              (page["object_type"] as? String) == "video",
              let media = page["media_info"] as? [String: Any],
              let id = string(status["mblogid"]),
              let postedAt = date(status["created_at"]),
              let duration = number(media["duration"]) else { return nil }
        let user = status["user"] as? [String: Any]
        let cover = (page["page_pic"] as? String) ?? ((page["page_pic"] as? [String: Any])?["url"] as? String)
        return video(id: id, author: string(user?["screen_name"]) ?? "", authorID: string(user?["id"]) ?? "",
                     postedAt: postedAt, rawText: string(status["text_raw"]) ?? "", duration: duration,
                     coverURL: https(cover), rules: rules)
    }

    /// One mblog from m.weibo.cn search.
    static func cnVideo(_ mblog: [String: Any], rules: ReplayRules) -> ReplayVideo? {
        guard let page = mblog["page_info"] as? [String: Any],
              (page["type"] as? String) == "video",
              let id = string(mblog["bid"]),
              let postedAt = date(mblog["created_at"]),
              let duration = number((page["media_info"] as? [String: Any])?["duration"]) else { return nil }
        let user = mblog["user"] as? [String: Any]
        let cover = (page["page_pic"] as? [String: Any])?["url"] as? String
        return video(id: id, author: string(user?["screen_name"]) ?? "", authorID: string(user?["id"]) ?? "",
                     postedAt: postedAt, rawText: string(mblog["text"]) ?? "", duration: duration,
                     coverURL: https(cover), rules: rules)
    }

    /// weibo.com/ajax/profile/getWaterFallContent → videos and the next cursor.
    static func waterfall(_ root: [String: Any], rules: ReplayRules) -> (videos: [ReplayVideo], nextCursor: String?) {
        let data = root["data"] as? [String: Any]
        let list = data?["list"] as? [[String: Any]] ?? []
        let cursor = string(data?["next_cursor"]).flatMap { $0 == "-1" || $0 == "0" ? nil : $0 }
        return (list.compactMap { comVideo($0, rules: rules) }, cursor)
    }

    /// m.weibo.cn/api/container/getIndex search: mblogs sit in cards or card groups.
    static func search(_ root: [String: Any], rules: ReplayRules) -> [ReplayVideo] {
        var mblogs: [[String: Any]] = []
        func walk(_ card: [String: Any]) {
            if let mblog = card["mblog"] as? [String: Any] { mblogs.append(mblog) }
            for child in card["card_group"] as? [[String: Any]] ?? [] { walk(child) }
        }
        for card in (root["data"] as? [String: Any])?["cards"] as? [[String: Any]] ?? [] { walk(card) }
        var seen = Set<String>()
        return mblogs.compactMap { cnVideo($0, rules: rules) }.filter { seen.insert($0.id).inserted }
    }

    /// Playable MP4s from statuses/show, best first; scrubber images and
    /// plain-http links are dropped.
    static func streams(_ status: [String: Any]) -> [ReplayStream] {
        let media = (status["page_info"] as? [String: Any])?["media_info"] as? [String: Any]
        let list = media?["playback_list"] as? [[String: Any]] ?? []
        let streams = list.compactMap { entry -> ReplayStream? in
            let label = ((entry["meta"] as? [String: Any])?["label"] as? String) ?? ""
            let info = entry["play_info"] as? [String: Any]
            guard label.hasPrefix("mp4"), let raw = info?["url"] as? String,
                  let url = URL(string: raw), url.scheme == "https" else { return nil }
            return ReplayStream(label: label, url: url, height: Int(number(info?["height"]) ?? 0))
        }
        // 1080p and below: a 4K file of a three-hour game is too heavy to stream.
        let capped = streams.filter { $0.height <= 1080 }
        return (capped.isEmpty ? streams : capped).sorted { $0.height > $1.height }
    }

    // MARK: Grouping and matching

    /// Videos of the same teams within a day of each other become one game.
    static func groups(_ videos: [ReplayVideo]) -> [ReplayGroup] {
        var buckets: [(matchup: ReplayVideo.Matchup, day: Date, videos: [ReplayVideo])] = []
        var seen = Set<String>()
        for video in videos.sorted(by: { $0.postedAt > $1.postedAt }) where seen.insert(video.id).inserted {
            guard let matchup = video.matchup else { continue }
            if let index = buckets.firstIndex(where: {
                $0.matchup.key == matchup.key && abs($0.day.timeIntervalSince(video.gameDay)) <= 86_400
            }) {
                buckets[index].videos.append(video)
                // A titled date beats a guess from the posting time.
                if video.titledDay != nil { buckets[index].day = video.gameDay }
            } else {
                buckets.append((matchup, video.gameDay, [video]))
            }
        }
        return buckets.map { bucket in
            ReplayGroup(matchup: bucket.matchup, day: bucket.day, videos: sortedForPlayback(bucket.videos))
        }
        .sorted { $0.day != $1.day ? $0.day > $1.day : $0.latestPost > $1.latestPost }
    }

    /// Whole game first, then halves and quarters; same part: longest first
    /// (a cut-short upload is the worse copy), then earliest.
    static func sortedForPlayback(_ videos: [ReplayVideo]) -> [ReplayVideo] {
        videos.sorted {
            if $0.part.order != $1.part.order { return $0.part.order < $1.part.order }
            if abs($0.duration - $1.duration) > 60 { return $0.duration > $1.duration }
            return $0.postedAt < $1.postedAt
        }
    }

    /// Videos of this match: both teams agree, and the titled day (or the
    /// posting time) fits the kickoff. Old seasons' meetings match the
    /// search too, which is why the date check is not optional.
    static func videos(for home: String, away: String, kickoff: Date,
                       in videos: [ReplayVideo], rules: ReplayRules) -> [ReplayVideo] {
        let key = ReplayVideo.Matchup(left: home, right: away).key
        let kickoffDay = beijingDay(kickoff)
        var seen = Set<String>()
        let matched = videos.filter { video in
            guard video.matchup?.key == key, seen.insert(video.id).inserted,
                  video.postedAt >= kickoff.addingTimeInterval(-3600),
                  video.postedAt <= kickoff.addingTimeInterval(rules.windowHours * 3600 + 7 * 86_400) else { return false }
            if let titled = video.titledDay {
                return abs(titled.timeIntervalSince(kickoffDay)) <= 86_400
            }
            return video.postedAt <= kickoff.addingTimeInterval(rules.windowHours * 3600)
        }
        return sortedForPlayback(matched)
    }
}

struct ReplayStream: Hashable, Sendable {
    let label: String
    let url: URL
    let height: Int

    /// Weibo signs links for about an hour ("Expires=<unix time>").
    var expires: Date? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "Expires" }?.value.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    var qualityLabel: String {
        height >= 1080 ? "1080P" : height >= 720 ? "720P" : height > 0 ? "\(height)P" : label
    }
}
