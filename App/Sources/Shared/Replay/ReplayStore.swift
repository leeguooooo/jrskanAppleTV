import AVFoundation
import Combine
import Foundation

/// The 回看 list: recent recordings from the configured uploaders' feeds,
/// grouped by game. Kept in memory only; refetched when ten minutes old.
@MainActor
final class ReplayLibrary: ObservableObject {
    static let shared = ReplayLibrary()

    @Published private(set) var groups: [ReplayGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var lastLoad: Date?
    private let client: WeiboClient

    init(client: WeiboClient = .shared) {
        self.client = client
    }

    var config: AppConfig.Replay { AppConfigStore.shared.config.replay }

    /// Every video in the list, for matching a match screen against it.
    var videos: [ReplayVideo] { groups.flatMap(\.videos) }

    func refreshIfStale(now: Date = Date()) async {
        if let lastLoad, now.timeIntervalSince(lastLoad) < 10 * 60, !groups.isEmpty { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        let config = config
        guard config.enabled else { groups = []; return }
        isLoading = true
        defer { isLoading = false }
        let rules = config.rules
        let client = client
        // Two pages per uploader reach back about three days for the busier ones.
        let results = await withTaskGroup(of: Result<[ReplayVideo], Error>.self) { group in
            for uid in config.uploaders {
                group.addTask {
                    do {
                        let first = ReplayParsing.waterfall(try await client.uploaderVideos(uid: uid), rules: rules)
                        guard let cursor = first.nextCursor else { return .success(first.videos) }
                        let second = try? ReplayParsing.waterfall(try await client.uploaderVideos(uid: uid, cursor: cursor), rules: rules)
                        return .success(first.videos + (second?.videos ?? []))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var all: [Result<[ReplayVideo], Error>] = []
            for await result in group { all.append(result) }
            return all
        }
        let videos = results.flatMap { (try? $0.get()) ?? [] }
        if videos.isEmpty, let failure = results.lazy.compactMap({ result -> Error? in
            if case .failure(let error) = result { return error }
            return nil
        }).first {
            errorMessage = failure.localizedDescription
            return
        }
        errorMessage = nil
        lastLoad = Date()
        groups = ReplayParsing.groups(videos)
    }
}

/// Recordings of one match: a Weibo search for "主队vs客队 回放" plus what the
/// 回看 list already holds, filtered by both teams and the kickoff date.
@MainActor
final class MatchReplays: ObservableObject {
    enum State: Equatable {
        case idle, loading, loaded, failed(String)
    }

    @Published private(set) var videos: [ReplayVideo] = []
    @Published private(set) var state = State.idle

    let match: LiveMatch
    private let client: WeiboClient

    init(match: LiveMatch, client: WeiboClient = .shared) {
        self.match = match
        self.client = client
    }

    /// Only once the match is over: as soon as the provider says so, never
    /// while it says live, and with no provider state, once a game's usual
    /// length has passed since kickoff.
    static func isEligible(_ match: LiveMatch, now: Date = Date()) -> Bool {
        guard AppConfigStore.shared.config.replay.enabled,
              let kickoff = MatchSchedule.kickoff(from: match.time, now: now) else { return false }
        let status = MatchSchedule.status(for: match, now: now)
        if status == .finished { return true }
        if status.isLive { return false }
        return now.timeIntervalSince(kickoff) > 2.5 * 3600
    }

    func load(now: Date = Date()) async {
        guard state != .loading, Self.isEligible(match, now: now),
              let kickoff = MatchSchedule.kickoff(from: match.time, now: now) else { return }
        let config = AppConfigStore.shared.config.replay
        state = .loading
        let known = ReplayLibrary.shared.videos
        do {
            // Uploaders write either order ("76人vs热火" and "热火vs76人"), and
            // Weibo's search ranks them apart, so ask both ways.
            let found = try await search([
                "\(match.homeTeam)vs\(match.awayTeam)\(config.searchSuffix)",
                "\(match.awayTeam)vs\(match.homeTeam)\(config.searchSuffix)",
            ], rules: config.rules)
            videos = ReplayParsing.videos(for: match.homeTeam, away: match.awayTeam, kickoff: kickoff,
                                          in: found + known, rules: config.rules)
            state = .loaded
        } catch {
            videos = ReplayParsing.videos(for: match.homeTeam, away: match.awayTeam, kickoff: kickoff,
                                          in: known, rules: config.rules)
            state = videos.isEmpty ? .failed(error.localizedDescription) : .loaded
        }
    }

    /// Both queries at once; fails only when every one of them does.
    private func search(_ queries: [String], rules: ReplayRules) async throws -> [ReplayVideo] {
        let client = client
        let results = await withTaskGroup(of: Result<[ReplayVideo], Error>.self) { group in
            for query in queries {
                group.addTask {
                    do { return .success(ReplayParsing.search(try await client.searchVideos(query), rules: rules)) }
                    catch { return .failure(error) }
                }
            }
            var all: [Result<[ReplayVideo], Error>] = []
            for await result in group { all.append(result) }
            return all
        }
        var videos: [ReplayVideo] = []
        var lastError: Error?
        var succeeded = false
        for result in results {
            switch result {
            case .success(let found): videos += found; succeeded = true
            case .failure(let error): lastError = error
            }
        }
        if !succeeded, let lastError { throw lastError }
        return videos
    }
}

/// Plays one recording. Weibo's links expire after about an hour and a game
/// runs two to three, so when the item fails (or the link is about to run
/// out while paused) it fetches a fresh link and carries on from the same spot.
@MainActor
final class ReplayPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var errorMessage: String?
    @Published private(set) var quality: String?

    let video: ReplayVideo
    private let client: WeiboClient
    private var expires: Date?
    private var observers: [NSKeyValueObservation] = []
    private var rateObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    /// Where playback was last seen. A failed item's currentTime is not
    /// reliable, so recovery seeks back to this instead.
    private var lastPosition = CMTime.zero
    private var failureObserver: NSObjectProtocol?
    private var refreshes: [Date] = []
    private var isRefreshing = false

    init(video: ReplayVideo, client: WeiboClient = .shared) {
        self.video = video
        self.client = client
    }

    func start() async {
        guard player == nil else { return }
        await load(resumeAt: nil)
    }

    func stop() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        debugBreak?.cancel()
        observers.removeAll()
        rateObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
    }

    /// Called when playback resumes after a pause: a link that expired in the
    /// meantime is replaced before AVPlayer finds out the hard way.
    func refreshIfExpiring(now: Date = Date()) async {
        guard let expires, expires.timeIntervalSince(now) < 120, let player else { return }
        await load(resumeAt: player.currentTime())
    }

    private func load(resumeAt time: CMTime?) async {
        guard !isRefreshing else { return }
        // A link that keeps failing is not an expiry problem; stop looping.
        let now = Date()
        refreshes = refreshes.filter { now.timeIntervalSince($0) < 120 } + [now]
        guard refreshes.count <= 3 else {
            errorMessage = "这个视频一直播放失败，可能已被删除。"
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let streams = ReplayParsing.streams(try await client.status(video.id))
            guard let stream = streams.first else {
                errorMessage = "这个视频已经看不了了（可能被删除或设为仅粉丝可见）。"
                return
            }
            expires = stream.expires
            quality = stream.qualityLabel
            let item = AVPlayerItem(url: stream.url)
            observe(item)
            if let player {
                player.replaceCurrentItem(with: item)
            } else {
                // This screen owns the audio; the live player stops talking over it.
                let player = AVPlayer(playerItem: item)
                self.player = player
                rateObserver = player.observe(\.timeControlStatus) { [weak self] player, _ in
                    guard player.timeControlStatus != .paused else { return }
                    Task { @MainActor in await self?.refreshIfExpiring() }
                }
                timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 1), queue: .main) { [weak self] time in
                    MainActor.assumeIsolated {
                        guard let self, self.player?.currentItem?.status == .readyToPlay, time.seconds > 0 else { return }
                        self.lastPosition = time
                    }
                }
                #if DEBUG
                scheduleDebugBreak()
                #endif
            }
            if let time, time.isValid, time.seconds > 1 {
                await player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
                print("replay: resumed at \(Int(player?.currentTime().seconds ?? -1))s (asked \(Int(time.seconds))s)")
            }
            player?.play()
            errorMessage = nil
        } catch {
            errorMessage = "拿不到播放地址：\(error.localizedDescription)"
        }
    }

    private func observe(_ item: AVPlayerItem) {
        observers = [item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.recover() }
        }]
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recover() }
        }
    }

    private func recover() {
        let time = lastPosition
        print("replay: item failed at \(Int(time.seconds))s, fetching a fresh link")
        Task { await load(resumeAt: time) }
    }

    private var debugBreak: Task<Void, Never>?

    #if DEBUG
    /// `-replay-break-after <s>`: after that many seconds, swap in the same
    /// link with a broken signature, which the CDN answers 403 exactly like an
    /// expired one, to exercise recovery mid-game.
    private func scheduleDebugBreak() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-replay-break-after"), index + 1 < args.count,
              let seconds = Double(args[index + 1]) else { return }
        debugBreak = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, let player = self.player,
                  let url = (player.currentItem?.asset as? AVURLAsset)?.url,
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            components.queryItems = components.queryItems?.map { $0.name == "ssig" ? URLQueryItem(name: "ssig", value: "broken0000") : $0 }
            guard let broken = components.url else { return }
            print("replay: debug break at \(Int(self.lastPosition.seconds))s")
            let item = AVPlayerItem(url: broken)
            self.observe(item)
            player.replaceCurrentItem(with: item)
            await player.seek(to: self.lastPosition, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            player.play()
        }
    }
    #endif
}

extension ReplayVideo {
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    /// "全场 · 2:11:24 · 花查章"
    var summary: String {
        "\(part.label) · \(Self.durationText(duration)) · \(author)"
    }
}

extension ReplayGroup {
    /// "今天" / "昨天" / "11月24日", in Beijing days like the titles.
    func dayText(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ReplayParsing.beijing
        let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return "今天"
        case 1: return "昨天"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = ReplayParsing.beijing
            formatter.dateFormat = "M月d日"
            return formatter.string(from: day)
        }
    }

    /// "全场 + 上半场 + 下半场 · 3 个视频"
    var partsSummary: String {
        var parts: [String] = []
        for video in videos where !parts.contains(video.part.label) { parts.append(video.part.label) }
        return "\(parts.prefix(4).joined(separator: " · ")) · \(videos.count) 个视频"
    }
}
