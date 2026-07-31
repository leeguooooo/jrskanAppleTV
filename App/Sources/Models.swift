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

enum SportFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case hot = "热门"
    case basketball = "篮球"
    case football = "足球"

    var id: String { rawValue }

    func includes(_ match: LiveMatch) -> Bool {
        switch self {
        case .all:
            return true
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
