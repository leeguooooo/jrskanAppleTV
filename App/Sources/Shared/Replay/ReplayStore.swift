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
