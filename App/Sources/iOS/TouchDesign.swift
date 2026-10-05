import SwiftUI

/// Touch counterparts of the tvOS design pieces, sized for a finger or a
/// pointer instead of a remote. Shared by iPhone, iPad and the Mac Catalyst
/// build. The look follows Apple Sports: a black canvas, borderless cards,
/// bare team logos and scores that carry the weight, with colour kept for
/// the things that need it (live, selection).
enum TouchMetrics {
    static let corner: CGFloat = 22
    static let crest: CGFloat = 30
}

struct TouchBackground: View {
    var body: some View {
        Color.black.ignoresSafeArea()
    }
}

/// Card surface for list rows: a flat grouped-background tile, no hairline.
struct TouchCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: TouchMetrics.corner, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .contentShape(RoundedRectangle(cornerRadius: TouchMetrics.corner, style: .continuous))
    }
}

extension View {
    func touchCard() -> some View { modifier(TouchCard()) }
}

// MARK: - Live

/// A plain pulsing dot. The TV badge sits on a tinted capsule so it reads
/// from the sofa; at arm's length that capsule just looks like a smudge.
struct TouchLiveDot: View {
    var size: CGFloat = 7
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Palette.live)
            .frame(width: size, height: size)
            .opacity(pulsing ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}

// MARK: - List chrome

/// One quiet line under the large title: what is on, and how fresh it is.
/// A score-feed problem replaces the timestamp so it is not missed.
struct TouchListSummary: View {
    @EnvironmentObject private var model: MatchListModel
    var now = Date()

    var body: some View {
        HStack(spacing: 6) {
            Text(line)
                .foregroundStyle(.secondary)
            if let notice {
                Text("· \(notice)").foregroundStyle(Palette.accent)
            }
            if MatchSchedule.viewerIsOffFeedTime(now: now) {
                Image(systemName: "globe")
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("本机时间")
            }
        }
        .font(.subheadline)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private var notice: String? {
        if let scoreNotice = model.scoreNotice { return scoreNotice }
        if let scores = model.scoresUpdatedAt, now.timeIntervalSince(scores) > 120 { return "比分数据较旧" }
        return nil
    }

    private var line: String {
        var parts: [String] = []
        let live = model.liveCount
        if live > 0 { parts.append("\(live) 场进行中") }
        parts.append("共 \(model.matches.count) 场")
        if notice == nil, let updated = model.scoresUpdatedAt ?? model.lastUpdated {
            parts.append("\(Self.clock.string(from: updated)) 更新")
        }
        return parts.joined(separator: " · ")
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

struct TouchSectionHeader: View {
    let section: MatchSection

    var body: some View {
        HStack(spacing: 8) {
            if section.status.isLive { TouchLiveDot(size: 8) }
            Text(section.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Text("\(section.matches.count)")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Rows

struct TouchMatchRow: View {
    let match: LiveMatch
    var now = Date()
    @EnvironmentObject private var preferences: Preferences

    private var status: MatchStatus { MatchSchedule.status(for: match, now: now) }
    private var homeScore: Int? { match.scoreText == nil ? nil : match.providerState?.homeScore }
    private var awayScore: Int? { match.scoreText == nil ? nil : match.providerState?.awayScore }
    private var hasScore: Bool { homeScore != nil && awayScore != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            HStack(spacing: 12) {
                VStack(spacing: 10) {
                    team(match.homeTeam, logo: match.homeLogoURL, score: homeScore, trailing: isTrailing(homeScore, awayScore))
                    team(match.awayTeam, logo: match.awayLogoURL, score: awayScore, trailing: isTrailing(awayScore, homeScore))
                }
                if !hasScore { kickoff }
            }

            if let footer { footer }
        }
        .touchCard()
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(match.league)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if preferences.follows(match) {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
            }
            if match.isHot {
                Image(systemName: "flame.fill").font(.caption2).foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            trailingStatus
        }
    }

    private func team(_ name: String, logo: URL?, score: Int?, trailing: Bool) -> some View {
        HStack(spacing: 12) {
            TeamCrest(url: logo, teamName: name, size: TouchMetrics.crest, framed: false)
            Text(name)
                .font(.body.weight(.semibold))
                .foregroundStyle(trailing ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let score {
                Text("\(score)")
                    .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundStyle(trailing ? .secondary : .primary)
                    .contentTransition(.numericText(value: Double(score)))
                    .animation(.snappy, value: score)
            }
        }
        .frame(minHeight: 32)
    }

    /// Apple Sports greys out the side that is behind; a level game stays white.
    private func isTrailing(_ mine: Int?, _ theirs: Int?) -> Bool {
        guard let mine, let theirs else { return false }
        return mine < theirs
    }

    /// Kickoff time takes the score column until there is a score.
    private var kickoff: some View {
        let shown = MatchSchedule.displayTime(for: match.time, now: now)
        return VStack(alignment: .trailing, spacing: 2) {
            Text(shown.clock)
                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
            if !shown.day.isEmpty {
                Text(shown.day).font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var trailingStatus: some View {
        switch status {
        case .live(let label):
            HStack(spacing: 5) {
                TouchLiveDot()
                Text(label)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.live)
            }
        case .finished:
            Text("已结束").font(.footnote.weight(.medium)).foregroundStyle(.tertiary)
        case .scheduled:
            Text("未开赛").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
        case .interrupted(let label):
            Text(label).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
        case .upcoming(let minutes) where minutes <= 90:
            Text("\(minutes) 分钟后开赛").font(.footnote.weight(.semibold)).foregroundStyle(Palette.accent)
        case .upcoming, .unknown:
            EmptyView()
        }
    }

    /// Only the exceptions earn a line: where you left off, or no stream at all.
    /// "3 条线路" on every card was noise.
    private var footer: AnyView? {
        if let last = preferences.lastChannel(for: match.id) {
            return AnyView(
                Label("上次看的 \(last.name)", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            )
        }
        if match.sources.isEmpty {
            return AnyView(
                Label("暂无线路", systemImage: "nosign")
                    .font(.caption).foregroundStyle(.tertiary)
            )
        }
        return nil
    }
}

struct TouchSkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Shimmer().frame(width: 80, height: 11).clipShape(Capsule())
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 12) {
                    Shimmer().frame(width: TouchMetrics.crest, height: TouchMetrics.crest).clipShape(Circle())
                    Shimmer().frame(width: 140, height: 14).clipShape(Capsule())
                    Spacer()
                    Shimmer().frame(width: 24, height: 18).clipShape(Capsule())
                }
            }
        }
        .touchCard()
    }
}

/// Filter chips. Horizontal so all categories stay one thumb-swipe away. The
/// two lead sports always show; any other empty category is hidden rather
/// than offered as "热门 0".
struct TouchCategoryBar: View {
    @Binding var selection: SportFilter
    let filters: [SportFilter]
    let counts: [SportFilter: Int]

    private var shown: [SportFilter] {
        filters.filter {
            [.all, .basketball, .badminton].contains($0) || $0 == selection || (counts[$0] ?? 0) > 0
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(shown) { filter in
                    let isSelected = selection == filter
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { selection = filter }
                    } label: {
                        Text(filter.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .foregroundStyle(isSelected ? Color.black : Color.primary)
                            .background(
                                Capsule().fill(isSelected ? Color.white : Color(uiColor: .tertiarySystemFill))
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityValue("\(counts[filter] ?? 0) 场")
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
    }
}

struct TouchChannelRow: View {
    let number: Int
    let source: MatchSource
    let subtitle: String
    var isBusy = false
    var isLastWatched = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if isBusy {
                    ProgressView().tint(Palette.accent)
                } else {
                    Text("\(number)")
                        .font(.headline.monospacedDigit().weight(.bold))
                        .foregroundStyle(Palette.accent)
                }
            }
            .frame(width: 40, height: 40)
            .background(Palette.accent.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(source.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.primaryText)
                        .lineLimit(1)
                    if isLastWatched {
                        Text("上次观看")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Palette.accent.opacity(0.14), in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: isBusy ? "hourglass" : "play.fill")
                .font(.subheadline)
                .foregroundStyle(isBusy ? Palette.secondaryText : Palette.accent)
        }
        .touchCard()
    }
}

/// Inline notice sized for a phone; same tones as the TV banner.
struct TouchNotice: View {
    let message: String
    var tone: NoticeBanner.Tone = .warning
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.bold))
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: TouchMetrics.corner, style: .continuous)
                .fill(tint.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TouchMetrics.corner, style: .continuous)
                .strokeBorder(tint.opacity(0.45), lineWidth: 1)
        )
    }

    private var tint: Color {
        switch tone {
        case .warning: return Palette.accent
        case .error: return Palette.live
        case .info: return Palette.secondaryText
        }
    }

    private var symbol: String {
        switch tone {
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }
}

/// Empty / error state for the phone: illustration, title, message, one action.
struct TouchStatusState: View {
    let title: String
    var message: String?
    var illustration: String?
    var systemImage = "sportscourt"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            if let illustration {
                Image(illustration)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 140)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Palette.accent)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(Palette.primaryText)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

/// Resume card at the top of the list, styled like any other row.
struct TouchContinueWatching: View {
    let match: LiveMatch

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("继续观看").font(.headline)
                Text("\(match.homeTeam) vs \(match.awayTeam)")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .touchCard()
        .accessibilityElement(children: .combine)
    }
}
