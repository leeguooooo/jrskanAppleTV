import SwiftUI

// MARK: - Palette

/// The app's colour vocabulary. The amber accent is the same hue as the app
/// icon's play mark, so the icon, the Top Shelf banner and the UI read as one
/// brand once the app is focused on the Home screen.
enum Palette {
    static let accent = Color(red: 1.00, green: 0.69, blue: 0.18)
    static let live = Color(red: 0.95, green: 0.26, blue: 0.21)

    static let backgroundTop = Color(red: 0.055, green: 0.075, blue: 0.11)
    static let backgroundBottom = Color(red: 0.015, green: 0.02, blue: 0.035)

    static let surface = Color.white.opacity(0.055)
    static let surfaceFocused = Color.white.opacity(0.14)
    static let hairline = Color.white.opacity(0.10)

    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.40)

    static var background: LinearGradient {
        LinearGradient(
            colors: [backgroundTop, backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Metrics

enum Metrics {
    /// tvOS overscan-safe side margin. Everything aligns to this.
    static let gutter: CGFloat = 80
    static let cardCorner: CGFloat = 20
    static let cardSpacing: CGFloat = 28
    static let rowHeight: CGFloat = 118
}

// MARK: - Background

/// Full-bleed gradient plus a soft amber bloom in the top-left, echoing the
/// floodlight glow in the icon artwork.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Palette.background
            RadialGradient(
                colors: [Palette.accent.opacity(0.16), .clear],
                center: .init(x: 0.12, y: -0.05),
                startRadius: 0,
                endRadius: 1100
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Focus card

/// Card treatment for focusable rows and tiles: lifts, brightens and picks up
/// an amber rim when focused. Reading focus from the environment inside the
/// style's body is what makes this work — `ButtonStyleConfiguration` only
/// reports `isPressed`.
struct FocusCardButtonStyle: ButtonStyle {
    var corner: CGFloat = Metrics.cardCorner

    func makeBody(configuration: Configuration) -> some View {
        FocusCard(corner: corner, isPressed: configuration.isPressed) {
            configuration.label
        }
    }

    private struct FocusCard<Content: View>: View {
        let corner: CGFloat
        let isPressed: Bool
        @ViewBuilder var content: Content
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            content
                .background(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(isFocused ? Palette.surfaceFocused : Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(
                            isFocused ? Palette.accent.opacity(0.85) : Palette.hairline,
                            lineWidth: isFocused ? 3 : 1
                        )
                )
                .shadow(
                    color: .black.opacity(isFocused ? 0.55 : 0),
                    radius: isFocused ? 28 : 0,
                    y: isFocused ? 16 : 0
                )
                .scaleEffect(isPressed ? 0.97 : (isFocused ? 1.03 : 1.0))
                .animation(.spring(response: 0.32, dampingFraction: 0.75), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: isPressed)
        }
    }
}

/// Renders the label and nothing else. `.buttonStyle(.plain)` still lets tvOS
/// paint its own white focus plate behind the button, which fights any custom
/// focus treatment — supplying a style, even an empty one, suppresses it.
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Badges

/// Pulsing dot + LIVE wordmark. Used on cards and over the player.
struct LiveBadge: View {
    var compact = false
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Palette.live)
                .frame(width: 10, height: 10)
                .opacity(pulsing ? 0.35 : 1.0)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            if !compact {
                Text("LIVE")
                    .font(.caption.weight(.heavy))
                    .tracking(1.2)
            }
        }
        .foregroundStyle(Palette.live)
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.vertical, 6)
        .background(Palette.live.opacity(0.14), in: Capsule())
        .onAppear { pulsing = true }
    }
}

/// Small pill for league names, channel counts and similar metadata.
struct MetaPill: View {
    let text: String
    var systemImage: String?
    var tint: Color = Palette.secondaryText

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Team crest

/// Team logo with a graceful fallback: while loading it shows a shimmer, and
/// if the remote logo is missing it falls back to the team's first character
/// rather than an empty hole in the layout.
struct TeamCrest: View {
    let url: URL?
    let teamName: String
    var size: CGFloat = 64

    var body: some View {
        AsyncImage(url: url, transaction: .init(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit().padding(size * 0.10)
            case .empty:
                Shimmer().clipShape(Circle())
            default:
                monogram
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.07), in: Circle())
        .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private var monogram: some View {
        Text(teamName.prefix(1))
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(Palette.secondaryText)
    }
}

// MARK: - Loading

/// Sweeping highlight used by skeleton placeholders.
struct Shimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Rectangle()
                .fill(Palette.surface)
                .overlay(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: width * 0.55)
                    .offset(x: phase * width * 1.6)
                )
        }
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

/// Placeholder row shown while the first fetch is in flight, so the screen has
/// its final shape before the data lands instead of flashing a bare spinner.
struct MatchSkeletonRow: View {
    var body: some View {
        HStack(spacing: 24) {
            Circle().fill(Palette.surface).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                Shimmer().frame(width: 160, height: 16).clipShape(Capsule())
                Shimmer().frame(width: 420, height: 24).clipShape(Capsule())
            }
            Spacer()
            Shimmer().frame(width: 120, height: 20).clipShape(Capsule())
        }
        .padding(.horizontal, 32)
        .frame(height: Metrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .fill(Palette.surface.opacity(0.5))
        )
    }
}

// MARK: - Empty & error states

/// One styled state view for "nothing here" and "it broke", so both read the
/// same way instead of one being a system view and the other bespoke.
struct StatusState: View {
    let systemImage: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: systemImage)
                .font(.system(size: 76, weight: .light))
                .foregroundStyle(Palette.accent.opacity(0.85))

            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.primaryText)

            if let message {
                Text(message)
                    .font(.body)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
