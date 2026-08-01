import SwiftUI

/// A match row in the browse list: league and status on the left, the two
/// crests facing each other in the middle, kickoff time and channel count on
/// the right. Sized and spaced for a 10-foot viewing distance.
struct MatchCard: View {
    let match: LiveMatch

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
    }

    private var leading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(match.league)
                .font(.callout.weight(.bold))
                .foregroundStyle(Palette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if match.isHot {
                MetaPill(text: "热门", systemImage: "flame.fill", tint: Palette.live)
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
                .frame(width: 290, alignment: .trailing)

            Text("VS")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Palette.tertiaryText)

            Text(match.awayTeam)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(width: 290, alignment: .leading)

            TeamCrest(url: match.awayLogoURL, teamName: match.awayTeam)
        }
    }

    private var trailing: some View {
        VStack(alignment: .trailing, spacing: 6) {
            KickoffTime(raw: match.time)

            if match.sources.isEmpty {
                MetaPill(text: "暂无线路", systemImage: "nosign", tint: Palette.tertiaryText)
            } else {
                MetaPill(
                    text: "\(match.sources.count) 条线路",
                    systemImage: "dot.radiowaves.left.and.right",
                    tint: Palette.secondaryText
                )
            }
        }
        .frame(width: 230, alignment: .trailing)
    }
}

/// Kickoff shown as `08-01` over `06:00`. The feed hands back one
/// `"MM-dd HH:mm"` string, and rendering it on a single line either truncates
/// or forces the clock down to an unreadable size at 10 feet.
private struct KickoffTime: View {
    let raw: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let date {
                Text(date)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Palette.tertiaryText)
            }
            Text(clock)
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Palette.primaryText)
        }
    }

    private var parts: [Substring] {
        raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    }

    private var date: String? {
        parts.count == 2 ? String(parts[0]) : nil
    }

    private var clock: String {
        parts.count == 2 ? String(parts[1]) : raw
    }
}

/// Channel picker tile used on the detail screen. The leading numeral mirrors
/// the site's own 主播解说①～⑥ numbering so the mapping stays obvious.
struct ChannelCard: View {
    let number: Int
    let source: MatchSource
    let subtitle: String

    var body: some View {
        HStack(spacing: 24) {
            Text("\(number)")
                .font(.title2.monospacedDigit().weight(.bold))
                .foregroundStyle(Palette.accent)
                .frame(width: 62, height: 62)
                .background(Palette.accent.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(source.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            Image(systemName: "play.fill")
                .font(.title3)
                .foregroundStyle(Palette.accent)
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
    let counts: [SportFilter: Int]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(SportFilter.allCases) { filter in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { selection = filter }
                } label: {
                    CategoryChip(
                        title: filter.rawValue,
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
    let count: Int
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 10) {
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
