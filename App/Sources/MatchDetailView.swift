import SwiftUI

/// Match detail: a hero showing the fixture, then the channel list. Selecting a
/// channel opens the player as a full-screen cover rather than a push, so the
/// video genuinely fills the screen.
struct MatchDetailView: View {
    let match: LiveMatch

    @State private var channels: [MatchSource]?
    @State private var channelErrorMessage: String?
    @State private var selection: ChannelSelection?

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
        .task(id: match.id) { await loadChannels() }
        .fullScreenCover(item: $selection) { selection in
            PlayerScreen(
                match: match,
                channels: resolvedChannels,
                startAt: selection.index
            )
        }
    }

    /// Parsed channels when the source page gave us any, otherwise the homepage
    /// entries as a fallback so the screen is never a dead end.
    private var resolvedChannels: [MatchSource] {
        if let channels, !channels.isEmpty { return channels }
        return match.sources
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

                LiveBadge()
            }

            HStack(spacing: 24) {
                teamBlock(name: match.homeTeam, logo: match.homeLogoURL)

                VStack(spacing: 10) {
                    Text("VS")
                        .font(.title.weight(.heavy))
                        .foregroundStyle(Palette.tertiaryText)
                    Text(match.time)
                        .font(.title3.monospacedDigit().weight(.medium))
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize()
                }
                .frame(width: 200)

                teamBlock(name: match.awayTeam, logo: match.awayLogoURL)
            }
            .frame(maxWidth: .infinity)
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
            }

            if let channelErrorMessage {
                Label(channelErrorMessage, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(Palette.accent)
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
                message: "开赛前后线路才会陆续上线，稍后回来看看。"
            )
            .frame(height: 320)
        } else if channels == nil {
            VStack(spacing: 16) {
                ForEach(0..<3, id: \.self) { _ in
                    Shimmer()
                        .frame(height: 116)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
                }
            }
        } else {
            LazyVStack(spacing: 16) {
                ForEach(Array(resolvedChannels.enumerated()), id: \.element.id) { index, source in
                    Button {
                        selection = ChannelSelection(index: index)
                    } label: {
                        ChannelCard(
                            number: index + 1,
                            source: source,
                            subtitle: subtitle(for: source)
                        )
                    }
                    .buttonStyle(FocusCardButtonStyle())
                }
            }
        }
    }

    private func subtitle(for source: MatchSource) -> String {
        if channels?.isEmpty ?? true { return "备用入口 · 直接尝试播放" }
        if source.name.localizedCaseInsensitiveContains("高清") { return "高清频道" }
        return "主播解说"
    }

    // MARK: - Loading

    @MainActor
    private func loadChannels() async {
        channels = nil
        channelErrorMessage = nil

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
        channelErrorMessage = "没能读取具体频道，下面是首页备用入口。"
    }
}

/// `fullScreenCover(item:)` needs an `Identifiable` binding, and the selection
/// here is just an index — wrap it rather than conforming `Int` itself.
private struct ChannelSelection: Identifiable {
    let index: Int
    var id: Int { index }
}
