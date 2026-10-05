import SwiftUI

/// One fixture as a native list row, laid out like a scoreboard: both teams
/// and their scores on the left, a hairline, then the clock and competition.
/// Type sizes are the system's own (body / footnote) so it sits in a List
/// the way rows in Stocks or Settings do, instead of as a hand-made card.
struct ScoreboardRow: View {
    let match: LiveMatch
    var now = Date()
    @EnvironmentObject private var preferences: Preferences

    private var status: MatchStatus { MatchSchedule.status(for: match, now: now) }
    private var homeScore: Int? { match.scoreText == nil ? nil : match.providerState?.homeScore }
    private var awayScore: Int? { match.scoreText == nil ? nil : match.providerState?.awayScore }

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 8) {
                team(match.homeTeam, logo: match.homeLogoURL, score: homeScore, other: awayScore)
                team(match.awayTeam, logo: match.awayLogoURL, score: awayScore, other: homeScore)
            }
            Rectangle()
                .fill(.separator)
                .frame(width: 1 / 3)
                .padding(.vertical, 2)
            statusColumn
                .frame(width: 78, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func team(_ name: String, logo: URL?, score: Int?, other: Int?) -> some View {
        // A side that is behind steps back, the way a scoreboard dims it.
        let behind = score != nil && other != nil && score! < other!
        return HStack(spacing: 10) {
            TeamCrest(url: logo, teamName: name, size: 22, framed: false)
            Text(name)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let score {
                Text("\(score)")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(score)))
                    .animation(.snappy, value: score)
            }
        }
        .font(.body)
        .foregroundStyle(behind ? .secondary : .primary)
    }

    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            primaryStatus
                .font(.footnote.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 3) {
                if preferences.follows(match) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
                Text(match.sources.isEmpty ? "暂无线路" : match.league)
                    .foregroundStyle(match.sources.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var primaryStatus: some View {
        let shown = MatchSchedule.displayTime(for: match.time, now: now)
        let clock = shown.day.isEmpty || shown.day == "今天" ? shown.clock : "\(shown.day) \(shown.clock)"
        switch status {
        case .live(let label):
            HStack(spacing: 4) {
                TouchLiveDot(size: 6)
                Text(label)
            }
            .foregroundStyle(Palette.live)
        case .finished:
            Text("已结束").foregroundStyle(.secondary)
        case .interrupted(let label):
            Text(label).foregroundStyle(.secondary)
        case .upcoming(let minutes) where minutes <= 90:
            Text(clock).foregroundStyle(Palette.accent)
        case .upcoming, .scheduled, .unknown:
            Text(clock).foregroundStyle(.primary)
        }
    }
}

/// Follow / unfollow either side from a long press.
struct FollowMenu: View {
    let match: LiveMatch
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        ForEach([match.homeTeam, match.awayTeam], id: \.self) { team in
            let following = preferences.isFavorite(team)
            Button {
                preferences.toggleFavorite(team)
            } label: {
                Label(following ? "取消关注 \(team)" : "关注 \(team)",
                      systemImage: following ? "star.slash" : "star")
            }
        }
    }
}

/// Shape-only rows while the first fetch is in flight.
struct ScoreboardPlaceholderRow: View {
    var body: some View {
        ScoreboardRow(match: LiveMatch(
            id: "placeholder", league: "联赛名称", time: "", homeTeam: "主队名称占位",
            awayTeam: "客队名称", homeLogoURL: nil, awayLogoURL: nil, isHot: false, sources: []
        ))
        .redacted(reason: .placeholder)
    }
}
