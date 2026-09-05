import SwiftUI

/// Match detail: a hero showing the fixture, then the channel list. Selecting a
/// channel opens the player as a full-screen cover rather than a push, so the
/// video genuinely fills the screen.
struct MatchDetailView: View {
    let match: LiveMatch

    @EnvironmentObject private var preferences: Preferences

    @State private var channels: [MatchSource]?
    @State private var channelErrorMessage: String?
    @State private var playback: PlaybackRequest?
    @State private var resolvingIndex: Int?
    @State private var playbackErrorMessage: String?
    @State private var playbackNotice: String?
    /// Channels that connected but never produced a picture this visit, so
    /// automatic fallback never loops back onto one of them.
    @State private var stalledIndices: Set<Int> = []
    @State private var now = Date()
    @FocusState private var focusedChannelID: String?

    @Environment(\.dismiss) private var dismiss

    private let resolver = StreamResolver()
    private let minuteTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

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
        .task(id: match.id) { await loadChannels() }
        .background(
            PlayerPresenter(
                request: $playback,
                match: match,
                channels: resolvedChannels,
                onSelectChannel: { index in
                    Task { await startPlayback(at: index) }
                },
                onStall: { message in
                    handleStall(message)
                }
            )
        )
    }

    /// Parsed channels when the source page gave us any, otherwise the homepage
    /// entries as a fallback so the screen is never a dead end.
    private var resolvedChannels: [MatchSource] {
        if let channels, !channels.isEmpty { return channels }
        return match.sources
    }

    private var status: MatchStatus {
        MatchSchedule.status(for: match.time, now: now)
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
        }
    }

    private var kickoffColumn: some View {
        let shown = MatchSchedule.displayTime(for: match.time, now: now)
        return VStack(spacing: 10) {
            Text("VS")
                .font(.title.weight(.heavy))
                .foregroundStyle(Palette.tertiaryText)

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

                if let channels, !channels.isEmpty {
                    MetaPill(text: "\(channels.count) 条可用", tint: Palette.secondaryText)
                }

                if preferences.autoNextChannel, resolvedChannels.count > 1 {
                    MetaPill(text: "失效自动换下一条", systemImage: "arrow.triangle.2.circlepath", tint: Palette.tertiaryText)
                }
            }

            if let channelErrorMessage {
                NoticeBanner(message: channelErrorMessage, tone: .info)
            }

            if let playbackNotice {
                NoticeBanner(message: playbackNotice, tone: .info)
            }

            if let playbackErrorMessage {
                NoticeBanner(
                    message: playbackErrorMessage,
                    tone: .error,
                    actionTitle: nextUntriedIndex(after: playback?.index ?? resolvingIndex ?? -1).map { "试线路 \($0 + 1)" } ?? "重试",
                    action: {
                        let next = nextUntriedIndex(after: playback?.index ?? -1) ?? 0
                        Task { await startPlayback(at: next) }
                    }
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
        } else if channels == nil {
            VStack(spacing: 16) {
                ForEach(0..<3, id: \.self) { _ in
                    Shimmer()
                        .frame(height: 116)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
                }
            }
        } else {
            let lastWatched = preferences.lastChannel(for: match.id)
            LazyVStack(spacing: 16) {
                ForEach(Array(resolvedChannels.enumerated()), id: \.element.id) { index, source in
                    Button {
                        Task { await startPlayback(at: index) }
                    } label: {
                        ChannelCard(
                            number: index + 1,
                            source: source,
                            subtitle: resolvingIndex == index
                                ? "正在解析线路…"
                                : subtitle(for: source, index: index),
                            isBusy: resolvingIndex == index,
                            isLastWatched: lastWatched?.name == source.name
                        )
                    }
                    .buttonStyle(FocusCardButtonStyle())
                    .focused($focusedChannelID, equals: source.id)
                    .disabled(resolvingIndex != nil)
                }
            }
            .focusSection()
        }
    }

    private func subtitle(for source: MatchSource, index: Int) -> String {
        if stalledIndices.contains(index) { return "刚才没有画面" }
        if channels?.isEmpty ?? true { return "备用入口 · 直接尝试播放" }
        if source.name.localizedCaseInsensitiveContains("高清") { return "高清频道" }
        return "主播解说"
    }

    /// The next channel that has not already failed this visit, walking
    /// forward and wrapping around. `nil` when everything has been tried.
    private func nextUntriedIndex(after index: Int) -> Int? {
        let count = resolvedChannels.count
        guard count > 0 else { return nil }
        for offset in 1...count {
            let candidate = (index + offset) % count
            if candidate != index, !stalledIndices.contains(candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Playback

    /// Resolve first, present second — so a dead link surfaces as an error on
    /// this screen instead of an unexplained black player the viewer then has
    /// to back out of. With automatic fallback on, a link that fails to resolve
    /// moves straight on to the next channel; the viewer sees which one is
    /// being tried and where playback finally landed.
    @MainActor
    private func startPlayback(at startIndex: Int, resetStalls: Bool = true) async {
        let channels = resolvedChannels
        guard channels.indices.contains(startIndex) else { return }
        if resetStalls { stalledIndices = [] }
        playbackErrorMessage = nil
        playbackNotice = nil

        let tryOthers = preferences.autoNextChannel && channels.count > 1
        var index = startIndex
        var attempts = 0
        var failures: [String] = []

        defer { resolvingIndex = nil }

        while channels.indices.contains(index), attempts < channels.count {
            let source = channels[index]
            resolvingIndex = index
            do {
                let url = try await resolver.resolve(sourcePageURL: source.pageURL)
                preferences.rememberChannel(matchID: match.id, name: source.name, index: index)
                if index != startIndex {
                    playbackNotice = "线路 \(startIndex + 1) 无法解析，已自动改用线路 \(index + 1)「\(source.name)」。"
                }
                playback = PlaybackRequest(url: url, sourceName: source.name, index: index)
                return
            } catch {
                failures.append("线路 \(index + 1)：\(error.localizedDescription)")
                attempts += 1
                guard tryOthers, let next = nextUntriedIndex(after: index), next != startIndex || attempts < channels.count else { break }
                index = next
            }
        }

        playbackErrorMessage = failures.count > 1
            ? "试过 \(failures.count) 条线路都无法解析。\(failures.last ?? "")"
            : failures.first
    }

    /// The player connected but never showed a picture. Remember the channel,
    /// and either hop to the next one or explain and hand control back.
    private func handleStall(_ message: String) {
        let stalled = playback?.index
        if let stalled { stalledIndices.insert(stalled) }

        guard preferences.autoNextChannel,
              let stalled,
              let next = nextUntriedIndex(after: stalled)
        else {
            playbackErrorMessage = message
            return
        }

        playbackNotice = "线路 \(stalled + 1) 没有画面，正在自动尝试线路 \(next + 1)…"
        Task {
            // The stalled player is still animating out; presenting on top of
            // that dismissal is refused by UIKit.
            try? await Task.sleep(nanoseconds: 700_000_000)
            await startPlayback(at: next, resetStalls: false)
        }
    }

    // MARK: - Loading

    @MainActor
    private func loadChannels() async {
        channels = nil
        channelErrorMessage = nil

        defer { focusRememberedChannel() }

        for source in match.sources {
            do {
                let loaded = try await SourcePageClient().fetchChannels(from: source.pageURL)
                if !loaded.isEmpty {
                    channels = loaded
                    return
                }
            } catch {
                continue
            }
        }

        channels = []
        // With no homepage entries at all there is nothing to fall back to,
        // and the "备用入口" notice would be pointing at an empty list.
        if !match.sources.isEmpty {
            channelErrorMessage = "没能读取具体频道，下面是首页备用入口。"
        }
    }

    /// Land focus on the channel the viewer used last time, or the first one,
    /// so a returning viewer is one press from playback.
    private func focusRememberedChannel() {
        let channels = resolvedChannels
        guard !channels.isEmpty else { return }
        let remembered = preferences.lastChannel(for: match.id)
        let target = channels.first { $0.name == remembered?.name } ?? channels[0]
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
