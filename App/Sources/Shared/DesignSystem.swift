import Combine
import SwiftUI
import AVKit

/// Display-only branding below the native playback controls.
enum PlayerWatermark {
    static func install(on controller: AVPlayerViewController) {
        controller.loadViewIfNeeded()
        guard let overlay = controller.contentOverlayView else { return }
        let watermark = WatermarkView()
        watermark.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(watermark)
        NSLayoutConstraint.activate([
            watermark.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            watermark.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            watermark.topAnchor.constraint(equalTo: overlay.topAnchor),
            watermark.bottomAnchor.constraint(equalTo: overlay.bottomAnchor)
        ])
    }
}

/// The watermark text, driven by the remote config: by default it never stops
/// gliding from one random spot to the next (one leg per `interval` seconds,
/// rotating through the configured texts); it can also hop (fade out, reappear
/// elsewhere) or sit bottom-right. It keeps out of
/// the top and bottom bands, where the playback controls appear.
final class WatermarkView: UIView {
    private let label = UILabel()
    private var settings: AppConfig.Watermark?
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private var textIndex = 0
    private var placed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        #if os(tvOS)
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        #else
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        #endif
        label.textColor = .white
        label.shadowColor = .black.withAlphaComponent(0.5)
        label.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(label)
        subscription = AppConfigStore.shared.watermark
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.apply($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { timer?.invalidate() }

    private func apply(_ settings: AppConfig.Watermark?) {
        self.settings = settings
        label.isHidden = settings == nil
        guard let settings else { return restartTimer() }
        label.layer.removeAllAnimations()
        label.alpha = settings.opacity
        textIndex = 0
        setText(settings.texts[0])
        placed = false
        setNeedsLayout()
        restartTimer()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restartTimer()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let settings, bounds.width > 0 else { return }
        if settings.motion == .fixed {
            // Where the watermark always sat: the bottom-right corner of the safe area.
            let corner = bounds.inset(by: safeAreaInsets).insetBy(dx: 20, dy: 20)
            label.frame.origin = CGPoint(x: corner.maxX - label.bounds.width, y: corner.maxY - label.bounds.height)
        } else if !placed || !area.insetBy(dx: -1, dy: -1).contains(label.frame) {
            // First layout, or a rotation / resize left it outside the area.
            label.frame.origin = randomOrigin()
            placed = true
            if settings.motion == .drift { step() }
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard window != nil, let settings, settings.motion != .fixed else { return }
        let timer = Timer(timeInterval: settings.interval, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        guard let settings, bounds.width > 0 else { return }
        switch settings.motion {
        case .fixed:
            break
        case .hop:
            UIView.animate(withDuration: 0.6, animations: { self.label.alpha = 0 }, completion: { _ in
                guard let settings = self.settings else { return }
                self.advanceText()
                self.label.frame.origin = self.randomOrigin()
                UIView.animate(withDuration: 0.6) { self.label.alpha = settings.opacity }
            })
        case .drift:
            advanceText()
            UIView.animate(withDuration: settings.interval, delay: 0,
                           options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction]) {
                self.label.frame.origin = self.randomOrigin()
            }
        }
    }

    private func advanceText() {
        guard let texts = settings?.texts, texts.count > 1 else { return }
        textIndex = (textIndex + 1) % texts.count
        setText(texts[textIndex])
    }

    private func setText(_ text: String) {
        label.text = text
        label.sizeToFit()
    }

    /// Inside the safe area with a margin, clear of the control bands.
    private var area: CGRect {
        let safe = bounds.inset(by: safeAreaInsets).insetBy(dx: 20, dy: 20)
        let top = safe.minY + safe.height * 0.15
        let bottom = safe.maxY - safe.height * 0.2
        return CGRect(x: safe.minX, y: top, width: safe.width, height: max(0, bottom - top))
    }

    private func randomOrigin() -> CGPoint {
        let area = area
        let size = label.bounds.size
        return CGPoint(
            x: CGFloat.random(in: area.minX...max(area.minX, area.maxX - size.width)),
            y: CGFloat.random(in: area.minY...max(area.minY, area.maxY - size.height))
        )
    }
}

// MARK: - Palette

/// leeguoo's cobalt/coral identity, lightened for readable controls on dark surfaces.
enum Palette {
    static let accent = Color(red: 0.50, green: 0.58, blue: 1.00)
    static let live = Color(red: 1.00, green: 0.33, blue: 0.28)

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

/// A quiet dark canvas with the blue brand accent, keeping artwork and labels separate.
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
/// a blue rim when focused. Reading focus from the environment inside the
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
    /// Draws the logo bare, the way Apple Sports does, and keeps the disc only
    /// behind the monogram fallback so a missing logo still has a shape.
    var framed = true

    var body: some View {
        AsyncImage(url: url, transaction: .init(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit().padding(framed ? size * 0.10 : 0)
            case .empty:
                Shimmer().clipShape(Circle())
            default:
                monogram
                    .frame(width: size, height: size)
                    .background(framed ? .clear : Color.white.opacity(0.08), in: Circle())
            }
        }
        .frame(width: size, height: size)
        .background(framed ? Color.white.opacity(0.07) : .clear, in: Circle())
        .overlay(Circle().strokeBorder(framed ? Palette.hairline : .clear, lineWidth: 1))
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
    /// Asset-catalog illustration shown instead of the symbol when present.
    var illustration: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 22) {
            if let illustration {
                Image(illustration)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 210)
                    .padding(.bottom, 6)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 76, weight: .light))
                    .foregroundStyle(Palette.accent.opacity(0.85))
            }

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

/// Names of the generated empty-state artwork in the asset catalog. Built by
/// `assets/brand/build_assets.py` from the source illustrations.
enum Illustration {
    static let noMatches = "EmptyNoMatch"
    static let offline = "EmptyOffline"
    static let noChannel = "EmptyNoChannel"
    static let search = "EmptySearch"
}

// MARK: - Notices

/// Inline notice for problems that should not take over the screen: a refresh
/// that failed while yesterday's list is still usable, a channel that died
/// while others are still worth trying. Carries at most one action so the
/// viewer's next press is obvious.
struct NoticeBanner: View {
    enum Tone { case warning, error, info }

    let message: String
    var tone: Tone = .warning
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)

            Text(message)
                .font(.callout.weight(.medium))
                .foregroundStyle(Palette.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 16)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.callout.weight(.bold))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                }
                .buttonStyle(FocusCardButtonStyle(corner: 14))
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .fill(tint.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
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

/// Section header used between the "on now / up next / over" groups.
struct SectionHeader: View {
    let title: String
    let count: Int
    var isLive = false

    var body: some View {
        HStack(spacing: 14) {
            if isLive {
                LiveBadge(compact: true)
            }
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(isLive ? Palette.live : Palette.primaryText)
            Text("\(count)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(Palette.tertiaryText)
            Spacer()
        }
        .padding(.top, 18)
        .padding(.bottom, 4)
        .padding(.leading, 6)
    }
}

/// Status and period clock from the website event feed, shared across screens.
struct StatusLabel: View {
    let status: MatchStatus
    var compact = false

    var body: some View {
        switch status {
        case .live(let label):
            HStack(spacing: 10) {
                LiveBadge()
                // The website supplies the period; never use kickoff elapsed time.
                Text(label)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Palette.live)
            }
        case .upcoming(let minutes) where minutes <= 90:
            MetaPill(text: "\(minutes) 分钟后开赛", systemImage: "clock", tint: Palette.accent)
        case .upcoming:
            EmptyView()
        case .finished:
            MetaPill(text: "已结束", systemImage: "checkmark", tint: Palette.tertiaryText)
        case .scheduled:
            MetaPill(text: "未开赛", systemImage: "clock", tint: Palette.accent)
        case .interrupted(let label):
            MetaPill(text: label, systemImage: "pause.circle", tint: Palette.secondaryText)
        case .unknown:
            EmptyView()
        }
    }
}
