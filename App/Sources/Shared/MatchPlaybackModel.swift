import Combine
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
    /// Seconds to seek to before playing: a replay picking up where it was
    /// left, or after its link was renewed. Live streams start at the edge.
    var startAt: Double? = nil
}

/// Everything a match screen needs to know about channels and playback,
/// independent of how the screen is drawn: which channels exist, which one is
/// being resolved, what is playing, what failed, and what to try next. The
/// tvOS and iPhone detail screens both drive this and only differ in layout.
@MainActor
final class MatchPlaybackModel: ObservableObject {
    /// A replay (回看) instead of a live match: the "channels" are the uploads
    /// of one game, played as MP4 links from Weibo. Live-only behaviour is off
    /// for it: no channel ranking or history, no 最近观看 entry, no hopping to
    /// another upload when one fails (each has its own timeline).
    struct ReplaySet {
        let videos: [ReplayVideo]
        /// The real fixture for statistics, when it could be pinned down.
        let fixture: LiveMatch?
    }

    let match: LiveMatch
    let preferences: Preferences
    let insights = MatchInsightsModel()
    let replay: ReplaySet?
    var isReplay: Bool { replay != nil }

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
    /// The playing channel was picked by hand rather than by priority.
    @Published private(set) var choseManually = false

    private let resolver: StreamResolver
    private let sourcePages: SourcePageClient
    private var requestGeneration = 0
    private var confirmedRequestID: UUID?
    private var confirmedAt: Date?
    private var handledFailureID: UUID?
    private var lastReconnect: [Int: Date] = [:]
    private var recoveryTask: Task<Void, Never>?
    private var resolutionDuration: TimeInterval = 0
    /// Replay: where playback was last seen, and when it was last saved.
    private var lastPosition: Double = 0
    private var lastSaved = Date.distantPast
    private var replayInsights: Task<Void, Never>?

    init(
        match: LiveMatch,
        preferences: Preferences,
        resolver: StreamResolver = StreamResolver(),
        sourcePages: SourcePageClient = SourcePageClient(),
        replay: ReplaySet? = nil
    ) {
        self.match = match
        self.preferences = preferences
        self.resolver = resolver
        self.sourcePages = sourcePages
        self.replay = replay
        if let replay { channels = Self.replaySources(replay.videos) }
    }

    /// One game's uploads as a player model. `fixture` is the real match when
    /// known (opened from it, or found on ESPN): it orders the teams and feeds
    /// the statistics; without it the panel says there is no data.
    static func replay(_ videos: [ReplayVideo], fixture: LiveMatch?, preferences: Preferences) -> MatchPlaybackModel {
        let first = videos.first
        let key = first?.matchup?.key ?? first?.id ?? "replay"
        let day = first.map { Int($0.gameDay.timeIntervalSince1970) } ?? 0
        let match = LiveMatch(
            id: "replay:\(key)@\(day)", league: fixture?.league ?? "回看", time: fixture?.time ?? "",
            homeTeam: fixture?.homeTeam ?? first?.matchup?.left ?? "", awayTeam: fixture?.awayTeam ?? first?.matchup?.right ?? "",
            homeLogoURL: fixture?.homeLogoURL, awayLogoURL: fixture?.awayLogoURL, isHot: false, sources: [])
        return MatchPlaybackModel(match: match, preferences: preferences, replay: ReplaySet(videos: videos, fixture: fixture))
    }

    private static func replaySources(_ videos: [ReplayVideo]) -> [MatchSource] {
        videos.map { MatchSource(id: $0.id, name: "\($0.part.label) · \($0.author)", pageURL: $0.shareURL) }
    }

    /// The upload playing now, for 分享 and the title.
    var currentReplay: ReplayVideo? {
        guard let replay, let index = playback?.index ?? resolvingIndex, replay.videos.indices.contains(index) else { return nil }
        return replay.videos[index]
    }

    // MARK: - Channels

    /// Parsed channels when the source page gave us any, otherwise the homepage
    /// entries as a fallback so the screen is never a dead end.
    var resolvedChannels: [MatchSource] {
        if let replay { return Self.replaySources(replay.videos) }
        if let channels, !channels.isEmpty { return MatchSource.playbackOrdered(channels) }
        return MatchSource.playbackOrdered(match.sources)
    }

    var isLoadingChannels: Bool { channels == nil }

    var rememberedChannel: MatchSource? {
        guard let remembered = preferences.recentWatches.first(where: { $0.id == match.id }) else { return nil }
        return resolvedChannels.first { $0.name == remembered.channelName }
    }

    /// Where focus or the first tap should land: last time's channel, else the first.
    var suggestedChannel: MatchSource? {
        guard let index = preferences.rankedIndices(for: resolvedChannels, matchID: match.id).first else { return nil }
        return resolvedChannels[index]
    }

    func startSuggestedPlayback() async {
        guard let source = suggestedChannel, let index = resolvedChannels.firstIndex(of: source) else { return }
        choseManually = false
        await startPlayback(at: index)
    }

    /// The viewer overrode the automatic choice. Automatic fallback still
    /// runs if that channel dies; the label just stops saying 自动.
    func startManualPlayback(at index: Int) async {
        choseManually = true
        await startPlayback(at: index)
    }

    /// Channels best-first, the order automatic selection tries them in.
    var rankedChannelIndices: [Int] {
        if let replay { return Array(replay.videos.indices) }
        return preferences.rankedIndices(for: resolvedChannels, matchID: match.id)
    }

    var automaticFallbackEnabled: Bool {
        !isReplay && preferences.autoNextChannel && resolvedChannels.count > 1
    }

    func subtitle(for source: MatchSource, index: Int) -> String {
        if let replay, replay.videos.indices.contains(index) {
            if resolvingIndex == index { return "正在获取播放地址…" }
            return ReplayVideo.durationText(replay.videos[index].duration)
        }
        if resolvingIndex == index { return "正在解析线路…" }
        if stalledIndices.contains(index) { return "刚才没有画面" }
        if failedResolutionIndices.contains(index) { return "刚才未能播放" }
        if suggestedChannel?.id == source.id,
           (preferences.channelPerformance[source.pageURL.absoluteString]?.successes ?? 0) > 0 {
            return "推荐 · 曾播放成功"
        }
        if channels?.isEmpty ?? true { return "备用入口 · 直接尝试播放" }
        if source.name.localizedCaseInsensitiveContains("高清") { return "高清频道" }
        return "主播解说"
    }

    /// The highest-ranked remaining channel. `nil` when this visit has
    /// exhausted every alternative.
    func nextUntriedIndex(after index: Int) -> Int? {
        let count = resolvedChannels.count
        guard count > 0 else { return nil }
        let ordered = preferences.rankedIndices(for: resolvedChannels, matchID: match.id)
        for candidate in ordered {
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
            guard !Task.isCancelled else { return }
            do {
                let loaded = try await sourcePages.fetchChannels(from: source.pageURL)
                if !loaded.isEmpty {
                    channels = loaded
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
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
        if replay != nil {
            await startReplay(at: startIndex, resumeAt: nil)
            return
        }
        let channels = resolvedChannels
        guard !Task.isCancelled, channels.indices.contains(startIndex) else { return }
        requestGeneration += 1
        let generation = requestGeneration
        if resetStalls {
            recoveryTask?.cancel()
            lastReconnect = [:]
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
            let started = Date()
            do {
                let url = try await resolver.resolve(sourcePageURL: source.pageURL)
                guard generation == requestGeneration, !Task.isCancelled else { return }
                resolutionDuration = Date().timeIntervalSince(started)
                confirmedRequestID = nil
                handledFailureID = nil
                if index != startIndex {
                    notice = "线路 \(startIndex + 1) 暂不可用，已自动改用线路 \(index + 1)「\(source.name)」。"
                }
                playback = PlaybackRequest(url: url, sourceName: source.name, index: index)
                return
            } catch {
                guard generation == requestGeneration, !Task.isCancelled else { return }
                failedResolutionIndices.insert(index)
                preferences.recordPlaybackFailure(source: source)
                failures.append("线路 \(index + 1)：\(error.localizedDescription)")
                attempts += 1
                guard tryOthers, let next = nextUntriedIndex(after: index) else { break }
                index = next
            }
        }

        playback = nil

        if !stalledIndices.isEmpty {
            errorMessage = "当前线路都未能播放：\(stalledIndices.count) 条没有画面，"
                + "\(failedResolutionIndices.count) 条暂不可用。可以稍后重试。"
        } else {
            errorMessage = failures.count > 1
                ? "试过 \(failures.count) 条线路，暂时都无法播放。\(failures.last ?? "")"
                : failures.first
        }
    }

    func confirmPlayback(requestID: UUID, startupSeconds: TimeInterval) {
        if replay != nil {
            // Nothing to learn about channels, and a replay is not a 最近观看.
            confirmedRequestID = requestID
            confirmedAt = Date()
            return
        }
        guard let request = playback, request.id == requestID, confirmedRequestID != requestID,
              resolvedChannels.indices.contains(request.index) else { return }
        confirmedRequestID = requestID
        confirmedAt = Date()
        preferences.recordPlaybackSuccess(match: match, source: resolvedChannels[request.index],
            index: request.index, startup: resolutionDuration + startupSeconds)
    }

    /// Keep the controller on screen during recovery. A confirmed stream gets
    /// one same-channel reconnect per two minutes before trying other sources,
    /// and always gets one when it had been playing for a minute: on a weak
    /// network every channel hiccups now and then, and hopping to another
    /// one only restarts the wait on the same slow connection.
    func handleStall(_ message: String, requestID: UUID? = nil, now: Date = Date()) {
        if replay != nil {
            handleReplayStall(message, requestID: requestID, now: now)
            return
        }
        guard let request = playback, requestID == nil || request.id == requestID,
              handledFailureID != request.id, resolvedChannels.indices.contains(request.index) else { return }
        handledFailureID = request.id
        let index = request.index
        preferences.recordPlaybackFailure(source: resolvedChannels[index], now: now)
        let playedAWhile = confirmedAt.map { now.timeIntervalSince($0) >= 60 } == true
        let shouldReconnect = confirmedRequestID == request.id
            && (playedAWhile || lastReconnect[index].map { now.timeIntervalSince($0) >= 120 } != false)
        let next: Int
        if shouldReconnect {
            lastReconnect[index] = now
            next = index
            notice = "直播中断，正在重新连接线路 \(index + 1)…"
        } else {
            stalledIndices.insert(index)
            guard preferences.autoNextChannel, let candidate = nextUntriedIndex(after: index) else {
                playback = nil
                errorMessage = message
                return
            }
            next = candidate
            notice = "线路 \(index + 1) 中断，正在尝试线路 \(next + 1)…"
        }
        let generation = requestGeneration
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            guard let self, generation == self.requestGeneration, !Task.isCancelled else { return }
            await self.startPlayback(at: next, resetStalls: false)
        }
    }

    func stopPlayback() {
        if let video = currentReplay { ReplayResume.save(lastPosition, duration: video.duration, for: video.id) }
        replayInsights?.cancel()
        replayInsights = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        requestGeneration += 1
        resolvingIndex = nil
        playback = nil
    }

    // MARK: - Replay

    /// Fetches a fresh MP4 link (they expire in about an hour) and plays it
    /// from `resumeAt`, or from where this upload was last left off.
    private func startReplay(at index: Int, resumeAt: Double?) async {
        guard let replay, replay.videos.indices.contains(index), !Task.isCancelled else { return }
        requestGeneration += 1
        let generation = requestGeneration
        if resumeAt == nil {
            recoveryTask?.cancel()
            lastReconnect = [:]
            handledFailureID = nil
        }
        errorMessage = nil
        resolvingIndex = index
        defer { if requestGeneration == generation { resolvingIndex = nil } }
        if replayInsights == nil, let fixture = replay.fixture {
            let insights = insights
            replayInsights = Task { await insights.watch(match: fixture, channels: []) }
        }
        let video = replay.videos[index]
        do {
            let streams = ReplayParsing.streams(try await WeiboClient.shared.status(video.id))
            guard generation == requestGeneration, !Task.isCancelled else { return }
            guard let stream = streams.first else {
                playback = nil
                errorMessage = "这个视频已经看不了了（可能被删除或设为仅粉丝可见）。"
                return
            }
            let start = resumeAt ?? ReplayResume.position(for: video.id)
            if resumeAt == nil, let start {
                notice = "从上次看到的 \(ReplayVideo.durationText(start)) 接着播"
            }
            lastPosition = start ?? 0
            confirmedRequestID = nil
            playback = PlaybackRequest(url: stream.url, sourceName: "\(video.part.label) · \(video.author)",
                                       index: index, startAt: start)
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            playback = nil
            errorMessage = "拿不到播放地址：\(error.localizedDescription)"
        }
    }

    /// A replay that stops is almost always its link expiring: renew it and
    /// carry on at the same spot. Twice in 20 seconds means the upload itself
    /// is gone. Never move to another upload: its timeline is different.
    private func handleReplayStall(_ message: String, requestID: UUID?, now: Date) {
        guard let request = playback, requestID == nil || request.id == requestID,
              handledFailureID != request.id else { return }
        handledFailureID = request.id
        let index = request.index
        if let last = lastReconnect[index], now.timeIntervalSince(last) < 20 {
            playback = nil
            errorMessage = "这个视频一直播放失败，可能已被删除：\(message)"
            return
        }
        lastReconnect[index] = now
        notice = "播放中断，正在换新的播放地址…"
        let position = lastPosition
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.startReplay(at: index, resumeAt: position)
        }
    }

    /// The player's position, for resuming. Saved every few seconds.
    func reportPosition(_ seconds: Double, duration: Double?, now: Date = Date()) {
        guard let video = currentReplay, seconds.isFinite, seconds > 0 else { return }
        lastPosition = seconds
        guard now.timeIntervalSince(lastSaved) >= 5 else { return }
        lastSaved = now
        ReplayResume.save(seconds, duration: duration ?? video.duration, for: video.id)
    }

    /// Played to the end: next time it starts from the beginning.
    func replayFinished() {
        guard let video = currentReplay else { return }
        lastPosition = 0
        ReplayResume.save(0, duration: nil, for: video.id)
    }
}
