import Foundation
import CommonCrypto

enum JRSClientError: LocalizedError {
    case invalidResponse
    case missingListingScript

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "目标站点返回了无效响应。"
        case .missingListingScript:
            return "没有在首页找到比赛列表数据。"
        }
    }
}

struct JRSClient {
    struct Schedule {
        let matches: [LiveMatch]
        let eventURL: URL?
    }
    static let defaultHomepage = URL(string: "https://www.jrs03.com/")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    let homepageURL: URL
    let session: URLSession
    private let parser = JRSListingParser()

    init(
        homepageURL: URL = JRSClient.defaultHomepage,
        session: URLSession = .shared
    ) {
        self.homepageURL = homepageURL
        self.session = session
    }

    func fetchMatches() async throws -> [LiveMatch] {
        let schedule = try await fetchSchedule()
        guard let eventURL = schedule.eventURL else { return schedule.matches }
        do { return try await fetchEvents(from: eventURL).applying(to: schedule.matches) }
        catch {
            try Task.checkCancellation()
            return schedule.matches
        }
    }

    func fetchSchedule() async throws -> Schedule {
        let homepage = try await fetchText(from: homepageURL)
        guard let scriptURL = listingScriptURL(in: homepage) else {
            throw JRSClientError.missingListingScript
        }
        let script = try await fetchText(from: scriptURL)
        let matches = try parser.parse(
            script: script,
            relativeTo: homepageURL,
            playHosts: JRSListingParser.playHosts(inHomepage: homepage)
        )
        // index.js is only the initial list. The web page subsequently applies
        // the event snapshot configured by njs.js, including removing stale rows.
        do {
            guard let configURL = EventSnapshot.configURL(in: homepage, baseURL: homepageURL) else {
                return Schedule(matches: matches, eventURL: nil)
            }
            let config = try await fetchText(from: configURL)
            guard let eventURL = EventSnapshot.eventURL(in: config, baseURL: configURL) else {
                return Schedule(matches: matches, eventURL: nil)
            }
            return Schedule(matches: matches, eventURL: eventURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A missing/broken event feed must not erase the schedule or invent
            // live/final status. The static list remains usable without badges.
            try Task.checkCancellation()
            return Schedule(matches: matches, eventURL: nil)
        }
    }

    func fetchEvents(from url: URL) async throws -> EventSnapshot {
        try EventSnapshot.parse(try await fetchText(from: url))
    }

    private func listingScriptURL(in html: String) -> URL? {
        let candidates = html.regexCaptures(
            #"(?is)<script[^>]+src="([^"]*index\.js[^"]*)"#
        )
        guard let rawValue = candidates.first?[safe: 1] else {
            return nil
        }
        if rawValue.hasPrefix("//") {
            return URL(string: "https:\(rawValue)")
        }
        return URL(string: rawValue, relativeTo: homepageURL)?.absoluteURL
    }

    private func fetchText(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let text = String(data: data, encoding: .utf8)
        else {
            throw JRSClientError.invalidResponse
        }
        return text
    }
}

struct EventSnapshot {
    struct Event {
        let kickoff: Date
        let state: ProviderMatchState
    }
    let events: [String: Event]
    let updatedAt: Date

    static func configURL(in html: String, baseURL: URL) -> URL? {
        guard let raw = html.regexCaptures(
            #"(?i)((?:https?:)?//[^\s\"'<>]+/tmp/njs\.js)"#
        ).first?[safe: 1] else { return nil }
        return URL(string: raw.hasPrefix("//") ? "https:" + raw : raw, relativeTo: baseURL)?.absoluteURL
    }

    static func eventURL(in config: String, baseURL: URL) -> URL? {
        guard let raw = config.regexCaptures(
            #"["']base_zqlq_url["']\s*:\s*["']([^"']+)["']"#
        ).first?[safe: 1],
            let url = URL(string: raw.hasPrefix("//") ? "https:" + raw : raw, relativeTo: baseURL),
            var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true)
        else { return nil }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "callback" }
        query.append(URLQueryItem(name: "callback", value: "jrkanEvents"))
        components.queryItems = query
        return components.url
    }

    static func parse(_ response: String, now: Date = Date()) throws -> EventSnapshot {
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = text.regexCaptures(#"(?s)^[A-Za-z_$][\w$]*\s*\((.*)\)\s*;?$"#)
            .first?[safe: 1] ?? text
        var object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        if let envelope = object as? [String], envelope.count == 2,
           let ciphertext = Data(base64Encoded: envelope[0]) {
            // The website's public transport encoding (page.live-2.1-min.js).
            // Decode data only; never execute the returned JavaScript.
            let key = Array("abcdabcdabcdabcd".utf8)
            var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
            var count = 0
            let status = ciphertext.withUnsafeBytes { bytes in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), key, key.count,
                    nil, bytes.baseAddress, ciphertext.count, &plaintext, plaintext.count, &count)
            }
            guard status == kCCSuccess else { throw JRSClientError.invalidResponse }
            object = try JSONSerialization.jsonObject(with: Data(plaintext.prefix(count)))
        }
        guard let payload = object as? [String: Any], payload["success"] as? Bool == true,
              let timestamp = payload["time"] as? Double,
              let table = payload["list"] as? [String: Any],
              let fields = table["fields"] as? [String],
              let rows = table["values"] as? [[Any]],
              Set(["id", "sportid", "status", "st_first", "st_second"]).isSubset(of: Set(fields)),
              Set(fields).count == fields.count
        else { throw JRSClientError.invalidResponse }
        let updatedAt = Date(timeIntervalSince1970: timestamp)
        guard now.timeIntervalSince(updatedAt) < 10 * 60,
              updatedAt.timeIntervalSince(now) < 5 * 60 else { throw JRSClientError.invalidResponse }
        var events: [String: Event] = [:]
        for row in rows {
            guard row.count == fields.count else { throw JRSClientError.invalidResponse }
            let values = Dictionary(uniqueKeysWithValues: zip(fields, row))
            guard let id = values["id"] as? Int, let sport = values["sportid"] as? Int,
                  let code = values["status"] as? Int, let kickoff = values["st_first"] as? Double,
                  let period = values["st_second"] as? Double
            else { throw JRSClientError.invalidResponse }
            events["\(sport),\(id)"] = Event(kickoff: Date(timeIntervalSince1970: kickoff / 1000),
                state: ProviderMatchState(sportID: sport, code: code,
                    periodStartedAt: Date(timeIntervalSince1970: period / 1000), updatedAt: updatedAt,
                    matchType: values["mtype"] as? Int ?? 0,
                    homeScore: values["s1"] as? Int,
                    awayScore: values["s2"] as? Int,
                    homeHalfScore: values["hs1"] as? Int,
                    awayHalfScore: values["hs2"] as? Int,
                    homeCorners: values["corner1"] as? Int,
                    awayCorners: values["corner2"] as? Int))
        }
        return EventSnapshot(events: events, updatedAt: updatedAt)
    }

    func applying(to matches: [LiveMatch]) -> [LiveMatch] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MatchSchedule.feedTimeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return matches.compactMap { match in
            let ids = match.id.split(separator: ",")
            guard ids.count == 3, ids[1] == "1" || ids[1] == "2" else { return match }
            // An absent football/basketball row is removed by the web page too;
            // absence means "no longer listed", not proof the match finished.
            guard let event = events["\(ids[1]),\(ids[2])"] else { return nil }
            return LiveMatch(id: match.id, league: match.league,
                time: formatter.string(from: event.kickoff), homeTeam: match.homeTeam,
                awayTeam: match.awayTeam, homeLogoURL: match.homeLogoURL,
                awayLogoURL: match.awayLogoURL, isHot: match.isHot, sources: match.sources,
                providerState: event.state)
        }
    }
}

enum SourcePageClientError: LocalizedError {
    case noChannels
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noChannels:
            return "这个入口没有找到可选择的具体频道。"
        case .invalidResponse:
            return "频道页面暂时无法访问。"
        }
    }
}

/// Loads the second-level channel buttons exposed by a match source page.
/// The homepage only contains mirror entrances such as `直播①`; the actual
/// commentary choices (for example `中文高清 Q ⑤`) live on this page.
struct SourcePageClient {
    let session: URLSession
    private let parser = SourcePageParser()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchChannels(from sourcePageURL: URL) async throws -> [MatchSource] {
        var request = URLRequest(url: sourcePageURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(JRSClient.defaultHomepage.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(JRSClient.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<400).contains(httpResponse.statusCode),
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else {
            throw SourcePageClientError.invalidResponse
        }

        let channels = parser.parse(html: html, relativeTo: response.url ?? sourcePageURL)
        guard !channels.isEmpty else {
            throw SourcePageClientError.noChannels
        }
        return channels
    }
}
