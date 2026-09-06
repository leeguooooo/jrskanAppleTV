import SwiftUI

struct MatchDetailScreen: View {
    @StateObject private var model: MatchPlaybackModel
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var listModel: MatchListModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var now = Date()
    private let minuteTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init(match: LiveMatch, preferences: Preferences) {
        _model = StateObject(wrappedValue: MatchPlaybackModel(match: match, preferences: preferences))
    }

    private var match: LiveMatch {
        if let current = listModel.matches.first(where: { $0.id == model.match.id }) { return current }
        var fallback = model.match
        fallback.providerState = nil
        return fallback
    }
    private var status: MatchStatus { MatchSchedule.status(for: match, now: now) }

    var body: some View {
        ZStack {
            TouchBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    channelSection
                }
                .padding(horizontalSizeClass == .compact ? 16 : 28)
                .padding(.bottom, 32)
                // A detail pane on a 13-inch iPad is far wider than the
                // content needs; letting the cards run edge to edge there
                // stretches every row into an unreadable band.
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(match.league)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onReceive(minuteTick) { now = $0 }
        .task(id: match.id) {
            await model.loadChannels()
            #if DEBUG
            if DebugRoute.autoplay, let target = model.suggestedChannel,
               let index = model.resolvedChannels.firstIndex(of: target) {
                await model.startPlayback(at: index)
            }
            #endif
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.playback != nil },
            set: { if !$0 { model.stopPlayback() } }
        )) {
            TouchPlayerScreen(model: model)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                if match.isHot {
                    MetaPill(text: "热门", systemImage: "flame.fill", tint: Palette.live)
                }
                StatusLabel(status: status)
                Spacer()
            }

            HStack(alignment: .top, spacing: 12) {
                teamBlock(name: match.homeTeam, logo: match.homeLogoURL)
                kickoffColumn
                teamBlock(name: match.awayTeam, logo: match.awayLogoURL)
            }
        }
        .touchCard()
    }

    private var kickoffColumn: some View {
        let shown = MatchSchedule.displayTime(for: match.time, now: now)
        return VStack(spacing: 6) {
            Text("VS")
                .font(.title3.weight(.heavy))
                .foregroundStyle(Palette.tertiaryText)
            Text(shown.day.isEmpty ? shown.clock : "\(shown.day) \(shown.clock)")
                .font(.footnote.monospacedDigit().weight(.medium))
                .foregroundStyle(Palette.secondaryText)
            if MatchSchedule.viewerIsOffFeedTime(now: now) {
                Text("北京 \(match.time)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Palette.tertiaryText)
            }
        }
        .frame(width: 96)
        .padding(.top, 18)
    }

    private func teamBlock(name: String, logo: URL?) -> some View {
        VStack(spacing: 10) {
            TeamCrest(url: logo, teamName: name, size: 72)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
            FollowButton(team: name)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Channels

    private var channelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("选择线路")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Palette.primaryText)
                if let channels = model.channels, !channels.isEmpty {
                    Text("\(channels.count) 条可用")
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                }
                Spacer()
                if model.automaticFallbackEnabled {
                    Label("失效自动换", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(Palette.tertiaryText)
                }
            }

            if let channelNotice = model.channelNotice {
                TouchNotice(message: channelNotice, tone: .info)
            }
            if let notice = model.notice {
                TouchNotice(message: notice, tone: .info)
            }
            if let errorMessage = model.errorMessage {
                TouchNotice(
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
            TouchStatusState(
                title: "这场比赛还没有线路",
                message: "开赛前后线路才会陆续上线，稍后回来看看。",
                illustration: Illustration.noChannel
            )
        } else if model.isLoadingChannels {
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in
                    Shimmer()
                        .frame(height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: TouchMetrics.corner, style: .continuous))
                }
            }
        } else {
            let remembered = model.rememberedChannel
            VStack(spacing: 10) {
                ForEach(Array(model.resolvedChannels.enumerated()), id: \.element.id) { index, source in
                    Button {
                        Task { await model.startPlayback(at: index) }
                    } label: {
                        TouchChannelRow(
                            number: index + 1,
                            source: source,
                            subtitle: model.subtitle(for: source, index: index),
                            isBusy: model.resolvingIndex == index,
                            isLastWatched: remembered?.id == source.id
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.resolvingIndex != nil)
                }
            }
        }
    }
}

private struct FollowButton: View {
    let team: String
    @EnvironmentObject private var preferences: Preferences
    @EnvironmentObject private var listModel: MatchListModel

    var body: some View {
        let isFavorite = preferences.isFavorite(team)
        Button {
            preferences.toggleFavorite(team)
        } label: {
            Label(isFavorite ? "已关注" : "关注", systemImage: isFavorite ? "star.fill" : "star")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isFavorite ? Palette.accent : Palette.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Palette.surface))
                .overlay(Capsule().strokeBorder(isFavorite ? Palette.accent.opacity(0.6) : Palette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "取消关注 \(team)" : "关注 \(team)")
    }
}
