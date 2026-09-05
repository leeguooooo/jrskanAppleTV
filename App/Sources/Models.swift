import Foundation

struct LiveMatch: Identifiable, Hashable, Sendable {
    let id: String
    let league: String
    let time: String
    let homeTeam: String
    let awayTeam: String
    let homeLogoURL: URL?
    let awayLogoURL: URL?
    let isHot: Bool
    let sources: [MatchSource]
}

struct MatchSource: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let pageURL: URL
}

// MARK: - Schedule

/// Where a match sits relative to now, derived from the feed's kickoff string.
enum MatchStatus: Hashable, Sendable {
    case live(elapsedMinutes: Int)
    case upcoming(startsInMinutes: Int)
    case finished
    case unknown

    var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    /// Sort key: what's on now first, then what's next, then what's over.
    var rank: Int {
        switch self {
        case .live: return 0
        case .upcoming: return 1
        case .unknown: return 2
        case .finished: return 3
        }
    }

    var sectionTitle: String {
        switch self {
        case .live: return "正在进行"
        case .upcoming: return "即将开始"
        case .unknown: return "其他"
        case .finished: return "已结束"
        }
    }
}

/// The feed hands back one `"MM-dd HH:mm"` string in Beijing time and nothing
/// else — no year, no zone, no state. Everything the UI says about "now",
/// "in 20 minutes" or "已结束" is derived here so the cards, the detail hero
/// and the section headers can never disagree with each other.
enum MatchSchedule {
    static let feedTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    /// How long after kickoff a match still counts as in progress. Football
    /// runs ~2h, basketball ~2.5h; three hours covers overtime and delays
    /// without keeping yesterday's games pinned to the top of the list.
    static let liveWindow: TimeInterval = 3 * 60 * 60

    static func kickoff(from raw: String, now: Date = Date()) -> Date? {
        let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" })
        guard parts.count == 2 else { return nil }
        let dayParts = parts[0].split(separator: "-").compactMap { Int($0) }
        let clockParts = parts[1].split(separator: ":").compactMap { Int($0) }
        guard dayParts.count == 2, clockParts.count == 2 else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = feedTimeZone

        var components = DateComponents()
        components.year = calendar.component(.year, from: now)
        components.month = dayParts[0]
        components.day = dayParts[1]
        components.hour = clockParts[0]
        components.minute = clockParts[1]
        guard var date = calendar.date(from: components) else { return nil }

        // No year in the feed. Around New Year the naive guess lands a whole
        // year off, so snap to whichever year puts the date closest to today.
        let halfYear: TimeInterval = 182 * 24 * 60 * 60
        if date.timeIntervalSince(now) > halfYear,
           let shifted = calendar.date(byAdding: .year, value: -1, to: date) {
            date = shifted
        } else if now.timeIntervalSince(date) > halfYear,
                  let shifted = calendar.date(byAdding: .year, value: 1, to: date) {
            date = shifted
        }
        return date
    }

    static func status(for raw: String, now: Date = Date()) -> MatchStatus {
        guard let kickoff = kickoff(from: raw, now: now) else { return .unknown }
        let delta = now.timeIntervalSince(kickoff)
        if delta < 0 {
            return .upcoming(startsInMinutes: Int((-delta / 60).rounded(.up)))
        }
        if delta < liveWindow {
            return .live(elapsedMinutes: Int(delta / 60))
        }
        return .finished
    }

    /// Kickoff rendered in the viewer's own zone: a relative day word plus the
    /// clock. Beijing-time strings shown verbatim to someone in Tokyo or
    /// Vancouver are simply wrong, and a TV has no hover to explain them.
    static func displayTime(
        for raw: String,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> (day: String, clock: String) {
        guard let kickoff = kickoff(from: raw, now: now) else {
            let parts = raw.split(separator: " ", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : ("", raw)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone

        formatter.dateFormat = "HH:mm"
        let clock = formatter.string(from: kickoff)

        let day: String
        if calendar.isDateInToday(kickoff) {
            day = "今天"
        } else if calendar.isDateInTomorrow(kickoff) {
            day = "明天"
        } else if calendar.isDateInYesterday(kickoff) {
            day = "昨天"
        } else {
            formatter.dateFormat = "M月d日"
            day = formatter.string(from: kickoff)
        }
        return (day, clock)
    }

    /// True when the device is not on Beijing time, i.e. the displayed clock
    /// differs from the feed's and the raw value is worth showing as well.
    static func viewerIsOffFeedTime(timeZone: TimeZone = .current, now: Date = Date()) -> Bool {
        timeZone.secondsFromGMT(for: now) != feedTimeZone.secondsFromGMT(for: now)
    }
}

// MARK: - Filters

enum SportFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case followed = "关注"
    case hot = "热门"
    case basketball = "篮球"
    case football = "足球"

    var id: String { rawValue }

    var systemImage: String? {
        switch self {
        case .all: return nil
        case .followed: return "star.fill"
        case .hot: return "flame.fill"
        case .basketball: return "basketball.fill"
        case .football: return "soccerball"
        }
    }

    func includes(_ match: LiveMatch, favorites: Set<String> = []) -> Bool {
        switch self {
        case .all:
            return true
        case .followed:
            return favorites.contains(match.homeTeam) || favorites.contains(match.awayTeam)
        case .hot:
            return match.isHot
        case .basketball:
            return Self.basketballLeagues.contains {
                match.league.localizedCaseInsensitiveContains($0)
            }
        case .football:
            return !SportFilter.basketball.includes(match)
        }
    }

    private static let basketballLeagues = [
        "NBA", "WNBA", "CBA", "NBL", "篮", "篮球", "欧篮", "韩篮", "菲MPBL"
    ]
}
