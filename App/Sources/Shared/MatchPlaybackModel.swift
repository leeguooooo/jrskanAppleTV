import Foundation

/// A stream that has already been resolved to a playable URL.
///
/// Resolution deliberately happens *before* the player appears. Presenting an
/// empty player and resolving behind it meant the viewer stared at a black
/// screen with no feedback, and it forced the player to own error states it had
/// no good way to show.
struct PlaybackRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let sourceName: String
    let index: Int
}

/// Everything a match screen needs to know about channels and playback,
/// independent of how the screen is drawn: which channels exist, which one is
/// being resolved, what is playing, what failed, and what to try next. The
/// tvOS and iPhone detail screens both drive this and only differ in layout.
@MainActor
final class MatchPlaybackModel: ObservableObject {
    let match: LiveMatch
    let preferences: Preferences

    /// Second-level channels from the source page; `nil` while loading, empty
    /// when the page gave nothing usable.
    @Published private(set) var channels: [MatchSource]?
    @Published private(set) var channelNotice: String?
    @Published var playback: PlaybackRequest?
    @Published private(set) var resolvingIndex: Int?
    @Published var errorMessage: String?
    @Published var notice: String?
    /// Channels that connected but never produced a picture this visit, so
    /// automatic fallback never loops back onto one of them.
    @Published private(set) var stalledIndices: Set<Int> = []
    @Published private(set) var failedResolutionIndices: Set<Int> = []

    private let resolver: StreamResolver
    private let sourcePages: SourcePageClient
    private var requestGeneration = 0

    init(
        match: LiveMatch,
        preferences: Preferences,
        resolver: StreamResolver = StreamResolver(),
        sourcePages: SourcePageClient = SourcePageClient()
    ) {
        self.match = match
        self.preferences = preferences
        self.resolver = resolver
        self.sourcePages = sourcePages
    }

    // MARK: - Channels

    /// Parsed channels when the source page gave us any, otherwise the homepage
    /// entries as a fallback so the screen is never a dead end.
    var resolvedChannels: [MatchSource] {
        if let channels, !channels.isEmpty { return channels }
        return match.sources
    }

    var isLoadingChannels: Bool { channels == nil }

    var rememberedChannel: MatchSource? {
        guard let remembered = preferences.lastChannel(for: match.id) else { return nil }
        return resolvedChannels.first { $0.name == remembered.name }
    }

    /// Where focus or the first tap should land: last time's channel, else the first.
    var suggestedChannel: MatchSource? {
        rememberedChannel ?? resolvedChannels.first
    }

    var automaticFallbackEnabled: Bool {
        preferences.autoNextChannel && resolvedChannels.count > 1
    }

    func subtitle(for source: MatchSource, index: Int) -> String {
        if resolvingIndex == index { return "正在解析线路…" }
        if stalledIndices.contains(index) { return "刚才没有画面" }
        if failedResolutionIndices.contains(index) { return "刚才未能播放" }
        if channels?.isEmpty ?? true { return "备用入口 · 直接尝试播放" }
        if source.name.localizedCaseInsensitiveContains("高清") { return "高清频道" }
        return "主播解说"
    }

    /// The next channel that has not already failed this visit, walking
    /// forward and wrapping around. `nil` when everything has been tried.
    func nextUntriedIndex(after index: Int) -> Int? {
        let count = resolvedChannels.count
        guard count > 0 else { return nil }
        for offset in 1...count {
            let candidate = (index + offset) % count
            if candidate != index, !stalledIndices.contains(candidate),
               !failedResolutionIndices.contains(candidate) { return candidate }
        }
        return nil
    }

    /// Label for the one action on the error banner.
    var retryActionTitle: String {
        let current = playback?.index ?? resolvingIndex ?? -1
        if let next = nextUntriedIndex(after: current) { return "试线路 \(next + 1)" }
        return "重试"
    }

    func retryAfterError() async {
        let current = playback?.index ?? -1
        await startPlayback(at: nextUntriedIndex(after: current) ?? 0)
    }

    func loadChannels() async {
        channels = nil
        channelNotice = nil

        for source in match.sources {
            do {
                let loaded = try await sourcePages.fetchChannels(from: source.pageURL)
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
            channelNotice = "没能读取具体频道，下面是首页备用入口。"
        }
    }

    // MARK: - Playback

    /// Resolve first, present second — so a dead link surfaces as an error on
    /// this screen instead of an unexplained black player the viewer then has
    /// to back out of. With automatic fallback on, a link that fails to resolve
    /// moves straight on to the next channel; the viewer sees which one is
    /// being tried and where playback finally landed.
    func startPlayback(at startIndex: Int, resetStalls: Bool = true) async {
        let channels = resolvedChannels
        guard channels.indices.contains(startIndex) else { return }
        requestGeneration += 1
        let generation = requestGeneration
        if resetStalls {
            stalledIndices = []
            failedResolutionIndices = []
        }
        errorMessage = nil
        notice = nil

        let tryOthers = preferences.autoNextChannel && channels.count > 1
        var index = startIndex
        var attempts = 0
        var failures: [String] = []

        defer {
            if requestGeneration == generation { resolvingIndex = nil }
        }

        while channels.indices.contains(index), attempts < channels.count {
            let source = channels[index]
            resolvingIndex = index
            do {
                let url = try await resolver.resolve(sourcePageURL: source.pageURL)
                guard generation == requestGeneration, !Task.isCancelled else { return }
                preferences.rememberChannel(matchID: match.id, name: source.name, index: index)
                if index != startIndex {
                    notice = "线路 \(startIndex + 1) 暂不可用，已自动改用线路 \(index + 1)「\(source.name)」。"
                }
                playback = PlaybackRequest(url: url, sourceName: source.name, index: index)
                return
            } catch {
                guard generation == requestGeneration, !Task.isCancelled else { return }
                failedResolutionIndices.insert(index)
                failures.append("线路 \(index + 1)：\(error.localizedDescription)")
                attempts += 1
                guard tryOthers, let next = nextUntriedIndex(after: index) else { break }
                index = next
            }
        }

        if !stalledIndices.isEmpty {
            errorMessage = "当前线路都未能播放：\(stalledIndices.count) 条没有画面，"
                + "\(failedResolutionIndices.count) 条暂不可用。可以稍后重试。"
        } else {
            errorMessage = failures.count > 1
                ? "试过 \(failures.count) 条线路，暂时都无法播放。\(failures.last ?? "")"
                : failures.first
        }
    }

    /// The player connected but never showed a picture. Remember the channel,
    /// close the player, and either hop to the next one or explain and hand
    /// control back.
    func handleStall(_ message: String) {
        let stalled = playback?.index
        if let stalled { stalledIndices.insert(stalled) }
        playback = nil

        guard preferences.autoNextChannel,
              let stalled,
              let next = nextUntriedIndex(after: stalled)
        else {
            errorMessage = message
            return
        }

        notice = "线路 \(stalled + 1) 没有画面，正在自动尝试线路 \(next + 1)…"
        let generation = requestGeneration
        Task {
            // The stalled player is still animating out; presenting on top of
            // that dismissal is refused by UIKit.
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard generation == requestGeneration, !Task.isCancelled else { return }
            await startPlayback(at: next, resetStalls: false)
        }
    }

    func stopPlayback() {
        requestGeneration += 1
        resolvingIndex = nil
        playback = nil
    }
}
