import SwiftUI

/// Match detail: a hero showing the fixture, then the channel list. Selecting a
/// channel opens the player as a full-screen cover rather than a push, so the
/// video genuinely fills the screen.
struct MatchDetailView: View {
    @StateObject private var model: MatchPlaybackModel
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var listModel: MatchListModel

    @State private var now = Date()
    @FocusState private var focusedChannelID: String?

    @Environment(\.dismiss) private var dismiss

    private let minuteTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private let autoplay: Bool

    init(match: LiveMatch, preferences: Preferences, autoplay: Bool = false) {
        self.autoplay = autoplay
        _model = StateObject(wrappedValue: MatchPlaybackModel(match: match, preferences: preferences))
    }

    private var match: LiveMatch {
        if let current = listModel.matches.first(where: { $0.id == model.match.id }) { return current }
        var fallback = model.match
        fallback.providerState = nil
        return fallback
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    hero
                    channelSection
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 46)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // Hiding the navigation bar also takes away the stack's own Menu-to-pop
        // handling, so Menu fell through to the system and quit the app instead
        // of going back one level. Pop explicitly.
        .onExitCommand { dismiss() }
        .onReceive(minuteTick) { now = $0 }
        .task(id: match.id) {
            await model.loadChannels()
            focusSuggestedChannel()
            if autoplay { await model.startSuggestedPlayback() }
        }
        .background(
            PlayerPresenter(
                request: $model.playback,
                match: match,
                channels: model.resolvedChannels,
                onSelectChannel: { index in
                    Task { await model.startPlayback(at: index) }
                },
                onStall: { id, message in model.handleStall(message, requestID: id) },
                onConfirmed: { id, startup in model.confirmPlayback(requestID: id, startupSeconds: startup) },
                onStop: { model.stopPlayback() }
            )
        )
    }

    private var status: MatchStatus {
        MatchSchedule.status(for: match, now: now)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 14) {
                Text(match.league)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Palette.accent)

                if match.isHot {
                    MetaPill(text: "热门", systemImage: "flame.fill", tint: Palette.live)
                }

                StatusLabel(status: status)
            }

            HStack(spacing: 24) {
                teamBlock(name: match.homeTeam, logo: match.homeLogoURL)

                kickoffColumn
                    .frame(width: 240)

                teamBlock(name: match.awayTeam, logo: match.awayLogoURL)
            }
            .frame(maxWidth: .infinity)
            MatchStatisticsView(match: match)
            if match.providerState != nil {
                ScoreFreshnessLine(now: now)
            } else {
                Text("本场实时数据暂不可用").font(.caption).foregroundStyle(Palette.secondaryText)
            }
        }
    }

    private var kickoffColumn: some View {
        let shown = MatchSchedule.displayTime(for: match.time, now: now)
        return VStack(spacing: 10) {
            Text(match.scoreText ?? "VS")
                .font(.title.monospacedDigit().weight(.heavy))
                .foregroundStyle(match.scoreText == nil ? Palette.tertiaryText : Palette.primaryText)

            Text(shown.day.isEmpty ? shown.clock : "\(shown.day) \(shown.clock)")
                .font(.title3.monospacedDigit().weight(.medium))
                .foregroundStyle(Palette.secondaryText)
                .fixedSize()

            if MatchSchedule.viewerIsOffFeedTime(now: now) {
                Text("北京时间 \(match.time)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.tertiaryText)
                    .fixedSize()
            }
        }
    }

    /// Team blocks share the leftover width equally, so the fixture stays
    /// symmetrical around the VS column no matter how long either club's name
    /// is — a fixed width made long Spanish club names wrap to three lines.
    private func teamBlock(name: String, logo: URL?) -> some View {
        VStack(spacing: 18) {
            TeamCrest(url: logo, teamName: name, size: 128)
            Text(name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.55)
            FollowButton(team: name)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Channels

    private var channelSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("选择线路")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Palette.primaryText)

                if let channels = model.channels, !channels.isEmpty {
                    MetaPill(text: "\(channels.count) 条可用", tint: Palette.secondaryText)
                }

                if model.automaticFallbackEnabled {
                    MetaPill(text: "失效自动换下一条", systemImage: "arrow.triangle.2.circlepath", tint: Palette.tertiaryText)
                }
            }

            if let channelNotice = model.channelNotice {
                NoticeBanner(message: channelNotice, tone: .info)
            }

            if let notice = model.notice {
                NoticeBanner(message: notice, tone: .info)
            }

            if let errorMessage = model.errorMessage {
                NoticeBanner(
                    message: errorMessage,
                    tone: .error,
                    actionTitle: model.retryActionTitle,
                    action: { Task { await model.retryAfterError() } }
                )
            }

            channelList
        }
    }

    @ViewBuilder
    private var channelList: some View {
        if match.sources.isEmpty {
            StatusState(
                systemImage: "nosign",
                title: "这场比赛还没有线路",
                message: "开赛前后线路才会陆续上线，稍后回来看看。",
                illustration: Illustration.noChannel
            )
            .frame(height: 480)
        } else if model.isLoadingChannels {
            VStack(spacing: 16) {
                ForEach(0..<3, id: \.self) { _ in
                    Shimmer()
                        .frame(height: 116)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
                }
            }
        } else {
            let remembered = model.rememberedChannel
            LazyVStack(spacing: 16) {
                ForEach(Array(model.resolvedChannels.enumerated()), id: \.element.id) { index, source in
                    Button {
                        Task { await model.startPlayback(at: index) }
                    } label: {
                        ChannelCard(
                            number: index + 1,
                            source: source,
                            subtitle: model.subtitle(for: source, index: index),
                            isBusy: model.resolvingIndex == index,
                            isLastWatched: remembered?.id == source.id
                        )
                    }
                    .buttonStyle(FocusCardButtonStyle())
                    .focused($focusedChannelID, equals: source.id)
                    .disabled(model.resolvingIndex != nil)
                }
            }
            .focusSection()
        }
    }

    /// Land focus on the channel the viewer used last time, or the first one,
    /// so a returning viewer is one press from playback.
    private func focusSuggestedChannel() {
        guard let target = model.suggestedChannel else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            focusedChannelID = target.id
        }
    }
}

// MARK: - Follow

private struct FollowButton: View {
    let team: String
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var listModel: MatchListModel

    var body: some View {
        let isFavorite = preferences.isFavorite(team)
        Button {
            preferences.toggleFavorite(team)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                Text(isFavorite ? "已关注" : "关注")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(isFavorite ? Palette.accent : Palette.secondaryText)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
        }
        .buttonStyle(FocusCardButtonStyle(corner: 24))
        .accessibilityLabel(isFavorite ? "取消关注 \(team)" : "关注 \(team)")
    }
}
