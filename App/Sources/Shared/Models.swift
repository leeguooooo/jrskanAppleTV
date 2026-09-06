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
    var providerState: ProviderMatchState? = nil

    var scoreText: String? { providerState?.scoreText }
}

struct MatchSource: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let pageURL: URL
}

/// Status codes and period clocks used by jrs03.com's page.live script.
struct ProviderMatchState: Hashable, Sendable {
    let sportID: Int
    let code: Int
    let periodStartedAt: Date
    let updatedAt: Date
    var matchType = 0
    var homeScore: Int? = nil
    var awayScore: Int? = nil

    var scoreText: String? {
        guard code != 0, let homeScore, let awayScore,
              homeScore >= 0, awayScore >= 0 else { return nil }
        return "\(homeScore) - \(awayScore)"
    }

    func status(now: Date) -> MatchStatus? {
        // Do not keep an old live label indefinitely after a refresh failure.
        guard now.timeIntervalSince(updatedAt) < 10 * 60,
              updatedAt.timeIntervalSince(now) < 5 * 60 else { return nil }
        if code == 0 { return .scheduled }
        if sportID == 1 {
            switch code {
            case 1, 3:
                let elapsed = max(0, Int(now.timeIntervalSince(periodStartedAt) / 60))
                let minute = code == 1 ? elapsed : max(46, elapsed + 45)
                let limit = code == 1 ? 45 : 90
                return .live(label: minute > limit ? "\(limit)+" : "\(minute)′")
            case 2: return .live(label: "中场休息")
            case 4, 5: return .live(label: "加时赛")
            case 6: return .live(label: "点球大战")
            case 7: return .finished
            case 8: return .interrupted(label: "推迟")
            case 9: return .interrupted(label: "中断")
            case 10: return .interrupted(label: "腰斩")
            case 11: return .interrupted(label: "取消")
            case 12: return .interrupted(label: "待定")
            default: return nil
            }
        }
        if sportID == 2 {
            // The website adjusts period labels for two-half competitions.
            let periodCode = matchType == 2 && (code == 4 || code == 8) ? code / 2 : code
            let periods = [1: "第一节", 2: "第一节结束", 3: "第二节", 4: "第二节结束",
                           5: "第三节", 6: "第三节结束", 7: "第四节", 8: "加时"]
            if let label = periods[periodCode] { return .live(label: label) }
            switch code {
            case 9: return .finished
            case 10: return .interrupted(label: "中断")
            case 11: return .interrupted(label: "取消")
            case 12: return .interrupted(label: "推迟")
            case 13: return .interrupted(label: "腰斩")
            case 14: return .interrupted(label: "待定")
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - Schedule

/// Provider-confirmed match state, with scheduled countdowns when appropriate.
enum MatchStatus: Hashable, Sendable {
    case live(label: String)
    case upcoming(startsInMinutes: Int)
    case scheduled
    case interrupted(label: String)
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
        case .upcoming, .scheduled: return 1
        case .unknown, .interrupted: return 2
        case .finished: return 3
        }
    }

    var sectionTitle: String {
        switch self {
        case .live: return "正在进行"
        case .upcoming, .scheduled: return "未开赛"
        case .unknown, .interrupted: return "其他"
        case .finished: return "已结束"
        }
    }
}

/// Schedule times are used for display and upcoming countdowns only.
/// In-progress and final states come from the website's event feed.
enum MatchSchedule {
    static let feedTimeZone = TimeZone(identifier: "Asia/Shanghai")!

    /// League-name fallback used by the category chips. Live state itself uses
    /// the event feed's sport ID, never this heuristic.
    static func isBasketball(league: String) -> Bool {
        SportFilter.basketballLeagues.contains { league.localizedCaseInsensitiveContains($0) }
    }

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

    static func status(for match: LiveMatch, now: Date = Date()) -> MatchStatus {
        if let state = match.providerState, let status = state.status(now: now) {
            if status == .scheduled, let kickoff = kickoff(from: match.time, now: now), kickoff > now {
                return .upcoming(startsInMinutes: Int((kickoff.timeIntervalSince(now) / 60).rounded(.up)))
            }
            return status
        }
        return status(for: match.time, league: match.league, now: now)
    }

    static func status(for raw: String, league: String = "", now: Date = Date()) -> MatchStatus {
        guard let kickoff = kickoff(from: raw, now: now) else { return .unknown }
        let delta = now.timeIntervalSince(kickoff)
        if delta < 0 {
            return .upcoming(startsInMinutes: Int((-delta / 60).rounded(.up)))
        }
        return .unknown
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

        // Measured against the caller's `now`, not the system clock:
        // `isDateInToday` asks the real calendar, so a screen still showing
        // 23:59's data just after midnight would relabel every row while the
        // rest of the UI is still working from the previous minute's tick.
        let daysApart = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: kickoff)
        ).day ?? 0

        let day: String
        switch daysApart {
        case 0: day = "今天"
        case 1: day = "明天"
        case -1: day = "昨天"
        default:
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
            return MatchSchedule.isBasketball(league: match.league)
        case .football:
            return !SportFilter.basketball.includes(match)
        }
    }

    static let basketballLeagues = [
        "NBA", "WNBA", "CBA", "NBL", "篮", "篮球", "欧篮", "韩篮", "菲MPBL"
    ]
}
