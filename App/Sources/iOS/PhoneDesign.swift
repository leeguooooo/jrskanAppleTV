import SwiftUI

/// Phone-sized counterparts of the tvOS design pieces. Same palette, same
/// vocabulary, sized for a thumb instead of a remote.
enum PhoneMetrics {
    static let corner: CGFloat = 16
    static let crest: CGFloat = 40
}

struct PhoneBackground: View {
    var body: some View {
        ZStack {
            Palette.background
            RadialGradient(
                colors: [Palette.accent.opacity(0.18), .clear],
                center: .init(x: 0.1, y: -0.1),
                startRadius: 0,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

/// Card surface for list rows: the same lifted, hairlined tile as the TV
/// cards, without the focus treatment.
struct PhoneCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: PhoneMetrics.corner, style: .continuous)
                    .fill(Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PhoneMetrics.corner, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
    }
}

extension View {
    func phoneCard() -> some View { modifier(PhoneCard()) }
}

// MARK: - Rows

struct PhoneMatchRow: View {
    let match: LiveMatch
    var now = Date()
    @EnvironmentObject private var preferences: Preferences

    private var status: MatchStatus { MatchSchedule.status(for: match.time, now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(match.league)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Palette.accent)
                    .lineLimit(1)

                if preferences.follows(match) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(Palette.accent)
                }
                if match.isHot {
                    Image(systemName: "flame.fill")
                        .font(.caption2)
                        .foregroundStyle(Palette.live)
                }

                Spacer(minLength: 8)

                trailingStatus
            }

            HStack(spacing: 10) {
                TeamCrest(url: match.homeLogoURL, teamName: match.homeTeam, size: PhoneMetrics.crest)
                Text(match.homeTeam)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("VS")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Palette.tertiaryText)

                Text(match.awayTeam)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                TeamCrest(url: match.awayLogoURL, teamName: match.awayTeam, size: PhoneMetrics.crest)
            }

            HStack(spacing: 8) {
                channelText
                Spacer()
                if case .upcoming(let minutes) = status, minutes <= 90 {
                    Text("\(minutes) 分钟后开赛")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .phoneCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        let shown = MatchSchedule.displayTime(for: match.time, now: now)
        switch status {
        case .live(let elapsed):
            HStack(spacing: 6) {
                LiveBadge(compact: true)
                Text("\(elapsed)′")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(Palette.live)
            }
        case .finished:
            Text("已结束 · \(shown.clock)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.tertiaryText)
        case .upcoming, .unknown:
            Text(shown.day.isEmpty ? shown.clock : "\(shown.day) \(shown.clock)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private var channelText: some View {
        Group {
            if let last = preferences.lastChannel(for: match.id) {
                Label("上次 · \(last.name)", systemImage: "clock.arrow.circlepath")
            } else if match.sources.isEmpty {
                Label("暂无线路", systemImage: "nosign")
            } else {
                Label("\(match.sources.count) 条线路", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .font(.caption)
        .foregroundStyle(match.sources.isEmpty ? Palette.tertiaryText : Palette.secondaryText)
        .lineLimit(1)
    }
}

struct PhoneSkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Shimmer().frame(width: 90, height: 12).clipShape(Capsule())
            HStack(spacing: 10) {
                Circle().fill(Palette.surface).frame(width: PhoneMetrics.crest, height: PhoneMetrics.crest)
                Shimmer().frame(height: 16).clipShape(Capsule())
                Circle().fill(Palette.surface).frame(width: PhoneMetrics.crest, height: PhoneMetrics.crest)
            }
            Shimmer().frame(width: 70, height: 10).clipShape(Capsule())
        }
        .phoneCard()
    }
}

/// Filter chip row. Horizontal so all categories stay one thumb-swipe away.
struct PhoneCategoryBar: View {
    @Binding var selection: SportFilter
    let filters: [SportFilter]
    let counts: [SportFilter: Int]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters) { filter in
                    let isSelected = selection == filter
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { selection = filter }
                    } label: {
                        HStack(spacing: 6) {
                            if let systemImage = filter.systemImage {
                                Image(systemName: systemImage).font(.caption.weight(.semibold))
                            }
                            Text(filter.rawValue).font(.subheadline.weight(.semibold))
                            Text("\(counts[filter] ?? 0)")
                                .font(.caption2.monospacedDigit().weight(.bold))
                                .foregroundStyle(isSelected ? Palette.backgroundTop.opacity(0.7) : Palette.tertiaryText)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .foregroundStyle(isSelected ? Palette.backgroundTop : Palette.secondaryText)
                        .background(Capsule().fill(isSelected ? Palette.accent : Palette.surface))
                        .overlay(Capsule().strokeBorder(isSelected ? .clear : Palette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}

struct PhoneChannelRow: View {
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
        .phoneCard()
    }
}

/// Inline notice sized for a phone; same tones as the TV banner.
struct PhoneNotice: View {
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
            RoundedRectangle(cornerRadius: PhoneMetrics.corner, style: .continuous)
                .fill(tint.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PhoneMetrics.corner, style: .continuous)
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
struct PhoneStatusState: View {
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
