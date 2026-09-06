import SwiftUI

/// A match row in the browse list: league and status on the left, the two
/// crests facing each other in the middle, kickoff or live state and channel
/// count on the right. Sized and spaced for a 10-foot viewing distance.
struct MatchCard: View {
    let match: LiveMatch
    /// Passed in rather than read inside so every row re-evaluates against
    /// the same instant when the list's minute tick fires.
    var now = Date()

    @EnvironmentObject private var preferences: Preferences

    private var status: MatchStatus {
        MatchSchedule.status(for: match, now: now)
    }

    var body: some View {
        HStack(spacing: 32) {
            leading
            fixture
            Spacer(minLength: 24)
            trailing
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 12)
        .frame(minHeight: Metrics.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var leading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(match.league)
                .font(.callout.weight(.bold))
                .foregroundStyle(Palette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 8) {
                if preferences.follows(match) {
                    MetaPill(text: "关注", systemImage: "star.fill", tint: Palette.accent)
                }
                if match.isHot {
                    MetaPill(text: "热门", systemImage: "flame.fill", tint: Palette.live)
                }
            }
        }
        .frame(width: 190, alignment: .leading)
    }

    /// Fixed-width name columns, not `minWidth`: the crests have to land on the
    /// same x across every row, otherwise long team names shove them around and
    /// the list reads as ragged.
    private var fixture: some View {
        HStack(spacing: 18) {
            TeamCrest(url: match.homeLogoURL, teamName: match.homeTeam)

            Text(match.homeTeam)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(width: 270, alignment: .trailing)

            Text("VS")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Palette.tertiaryText)

            Text(match.awayTeam)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(width: 270, alignment: .leading)

            TeamCrest(url: match.awayLogoURL, teamName: match.awayTeam)
        }
    }

    private var trailing: some View {
        VStack(alignment: .trailing, spacing: 8) {
            switch status {
            case .live:
                StatusLabel(status: status, compact: true)
            case .finished:
                HStack(spacing: 12) {
                    KickoffTime(raw: match.time, now: now, dimmed: true)
                    StatusLabel(status: status)
                }
            case .upcoming, .scheduled, .interrupted, .unknown:
                KickoffTime(raw: match.time, now: now)
                StatusLabel(status: status)
            }

            channelPill
        }
        .frame(width: 270, alignment: .trailing)
    }

    @ViewBuilder
    private var channelPill: some View {
        if let last = preferences.lastChannel(for: match.id) {
            MetaPill(text: "上次 · \(last.name)", systemImage: "clock.arrow.circlepath", tint: Palette.secondaryText)
        } else if match.sources.isEmpty {
            MetaPill(text: "暂无线路", systemImage: "nosign", tint: Palette.tertiaryText)
        } else {
            MetaPill(
                text: "\(match.sources.count) 条线路",
                systemImage: "dot.radiowaves.left.and.right",
                tint: Palette.secondaryText
            )
        }
    }

    private var accessibilitySummary: String {
        let shown = MatchSchedule.displayTime(for: match.time, now: now)
        let state: String
        switch status {
        case .live(let label): state = "正在进行，\(label)"
        case .upcoming: state = "\(shown.day) \(shown.clock) 开赛"
        case .scheduled: state = "未开赛"
        case .interrupted(let label): state = label
        case .finished: state = "已结束"
        case .unknown: state = match.time
        }
        return "\(match.league)，\(match.homeTeam) 对 \(match.awayTeam)，\(state)，\(match.sources.count) 条线路"
    }
}

/// Kickoff shown as `今天` over `20:00`, in the viewer's own time zone.
/// Rendering the feed's `MM-dd HH:mm` on one line either truncates or forces
/// the clock down to an unreadable size at 10 feet.
struct KickoffTime: View {
    let raw: String
    var now = Date()
    var dimmed = false

    var body: some View {
        let shown = MatchSchedule.displayTime(for: raw, now: now)
        VStack(alignment: .trailing, spacing: 2) {
            if !shown.day.isEmpty {
                Text(shown.day)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.tertiaryText)
            }
            Text(shown.clock)
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(dimmed ? Palette.secondaryText : Palette.primaryText)
        }
    }
}

/// Channel picker tile used on the detail screen. The leading numeral mirrors
/// the site's own 主播解说①～⑥ numbering so the mapping stays obvious.
struct ChannelCard: View {
    let number: Int
    let source: MatchSource
    let subtitle: String
    var isBusy = false
    var isLastWatched = false

    var body: some View {
        HStack(spacing: 24) {
            ZStack {
                if isBusy {
                    ProgressView().tint(Palette.accent)
                } else {
                    Text("\(number)")
                        .font(.title2.monospacedDigit().weight(.bold))
                        .foregroundStyle(Palette.accent)
                }
            }
            .frame(width: 62, height: 62)
            .background(Palette.accent.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(source.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    if isLastWatched {
                        MetaPill(text: "上次观看", systemImage: "clock.arrow.circlepath", tint: Palette.accent)
                    }
                }

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            Image(systemName: isBusy ? "hourglass" : "play.fill")
                .font(.title3)
                .foregroundStyle(isBusy ? Palette.secondaryText : Palette.accent)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 20)
        .frame(minHeight: 116)
    }
}

/// Horizontal, focusable category selector. Replaces the segmented `Picker`,
/// which on tvOS reads as a form control rather than a browse affordance.
struct CategoryBar: View {
    @Binding var selection: SportFilter
    let filters: [SportFilter]
    let counts: [SportFilter: Int]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(filters) { filter in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { selection = filter }
                } label: {
                    CategoryChip(
                        title: filter.rawValue,
                        systemImage: filter.systemImage,
                        count: counts[filter] ?? 0,
                        isSelected: selection == filter
                    )
                }
                .buttonStyle(BareButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Three distinct looks, because focus and selection are independent on tvOS:
/// focused wins (solid amber), then selected (amber text on a lifted surface),
/// then resting. A selected chip must stay legible once focus moves into the
/// list below it.
private struct CategoryChip: View {
    let title: String
    let systemImage: String?
    let count: Int
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
            }
            Text(title)
                .font(.title3.weight(.semibold))
            Text("\(count)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(countForeground)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(countBackground, in: Capsule())
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 15)
        .foregroundStyle(titleForeground)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(border, lineWidth: isSelected ? 2 : 1))
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .animation(.easeOut(duration: 0.2), value: isSelected)
    }

    private var fill: Color {
        if isFocused { return Palette.accent }
        return isSelected ? Palette.surfaceFocused : Palette.surface
    }

    private var border: Color {
        if isFocused { return .clear }
        return isSelected ? Palette.accent.opacity(0.7) : Palette.hairline
    }

    private var titleForeground: Color {
        if isFocused { return Palette.backgroundTop }
        return isSelected ? Palette.accent : Palette.secondaryText
    }

    private var countForeground: Color {
        isFocused ? Palette.backgroundTop : Palette.secondaryText
    }

    private var countBackground: Color {
        isFocused ? Palette.backgroundTop.opacity(0.20) : Color.white.opacity(0.10)
    }
}

/// Icon-only control for the header row (search, refresh, settings). A
/// labelled `Button` here wraps to two lines once the chips grow, and the
/// glyphs are unambiguous at 10 feet.
struct HeaderIconButton: View {
    let systemImage: String
    let title: String
    var isBusy = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        ZStack {
            if isBusy {
                ProgressView().tint(isFocused ? Palette.backgroundTop : Palette.accent)
            } else {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
            }
        }
        .frame(width: 74, height: 62)
        .foregroundStyle(isFocused ? Palette.backgroundTop : Palette.primaryText)
        .background(Capsule().fill(isFocused ? Palette.accent : Palette.surface))
        .overlay(Capsule().strokeBorder(isFocused ? .clear : Palette.hairline, lineWidth: 1))
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .accessibilityLabel(title)
    }
}
