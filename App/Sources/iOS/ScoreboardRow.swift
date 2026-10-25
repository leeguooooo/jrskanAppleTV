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
                .fill(Palette.hairline)
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
            TeamCrest(url: logo, teamName: name, size: 26, framed: false)
            Text(name)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let score {
                LEDScore(text: "\(score)", size: 27, dimmed: behind)
                    .contentTransition(.numericText(value: Double(score)))
                    .animation(.snappy, value: score)
            }
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(behind ? Palette.secondaryText : Palette.primaryText)
    }

    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            primaryStatus
                .font(BrandFont.numeric(13, relativeTo: .footnote))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 3) {
                if preferences.follows(match) {
                    Image(systemName: "star.fill").foregroundStyle(Palette.accent)
                }
                Text(match.sources.isEmpty ? "暂无线路" : match.league)
                    .foregroundStyle(match.sources.isEmpty ? Palette.tertiaryText : Palette.secondaryText)
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
            Text("已结束").foregroundStyle(Palette.secondaryText)
        case .interrupted(let label):
            Text(label).foregroundStyle(Palette.secondaryText)
        case .upcoming(let minutes) where minutes <= 90:
            Text(clock).foregroundStyle(Palette.accent)
        case .upcoming, .scheduled, .unknown:
            Text(clock).foregroundStyle(Palette.primaryText)
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

/// The match to lead with: the first one on now, hot ones first. Tapping it
/// plays straight away, like any row.
struct LiveHeroCard: View {
    let match: LiveMatch
    var now = Date()

    private var status: MatchStatus { MatchSchedule.status(for: match, now: now) }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(match.league)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if case .live(let label) = status {
                    HStack(spacing: 5) {
                        TouchLiveDot(size: 6)
                        Text(label).font(BrandFont.numeric(13, bold: true, relativeTo: .footnote))
                    }
                    .foregroundStyle(Palette.live)
                }
            }

            HStack(alignment: .center, spacing: 8) {
                side(match.homeTeam, logo: match.homeLogoURL)
                score
                side(match.awayTeam, logo: match.awayLogoURL)
            }

            Label("观看直播", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
                .font(.headline.weight(.heavy))
                .foregroundStyle(Palette.onAccent)
                .padding(.vertical, 13)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: TouchMetrics.corner, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x1E1A15), Color(hex: 0x151210)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TouchMetrics.corner, style: .continuous)
                .strokeBorder(Color(hex: 0x3A3229), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: TouchMetrics.corner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("播放这场比赛")
    }

    @ViewBuilder
    private var score: some View {
        let home = match.scoreText == nil ? nil : match.providerState?.homeScore
        let away = match.scoreText == nil ? nil : match.providerState?.awayScore
        if let home, let away {
            HStack(spacing: 6) {
                LEDScore(text: "\(home)", size: 64)
                Text(":").font(BrandFont.score(64)).foregroundStyle(Palette.tertiaryText)
                LEDScore(text: "\(away)", size: 64)
            }
            .fixedSize()
            .layoutPriority(1)
        } else {
            Text("VS").font(BrandFont.score(52)).foregroundStyle(Palette.tertiaryText)
        }
    }

    private func side(_ name: String, logo: URL?) -> some View {
        VStack(spacing: 8) {
            TeamCrest(url: logo, teamName: name, size: 58, framed: false)
            Text(name)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

extension Array where Element == MatchSection {
    /// The hero match for a list: the first live one, preferring hot games.
    func heroMatch(now: Date) -> LiveMatch? {
        let live = first { $0.status.isLive }?.matches.filter { MatchSchedule.status(for: $0, now: now).isLive } ?? []
        return live.first { $0.isHot } ?? live.first
    }
}
