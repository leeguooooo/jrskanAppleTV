import Foundation

/// Talks to Weibo as an anonymous visitor, from the device itself.
///
/// Weibo runs two visitor identities: weibo.com (profile feeds, statuses/show)
/// and weibo.cn (m.weibo.cn search). A cookie from one is rejected by the
/// other, so each is minted from its own passport host. When Weibo answers a
/// request with 403, "ok":-100 or its visitor-system HTML page, the identity is
/// minted again and the request retried once.
actor WeiboClient {
    static let shared = WeiboClient()

    enum Site: Sendable {
        case com, cn

        var visitorEndpoint: URL {
            switch self {
            case .com: return URL(string: "https://passport.weibo.com/visitor/genvisitor2")!
            case .cn: return URL(string: "https://visitor.passport.weibo.cn/visitor/genvisitor2")!
            }
        }

        /// A URL whose cookies show whether this identity exists.
        var probe: URL {
            switch self {
            case .com: return URL(string: "https://weibo.com/")!
            case .cn: return URL(string: "https://m.weibo.cn/")!
            }
        }
    }

    enum Failure: Error, LocalizedError {
        case blocked
        case badResponse

        var errorDescription: String? {
            switch self {
            case .blocked: return "微博暂时拒绝了请求，稍后再试。"
            case .badResponse: return "微博返回的数据看不懂，可能改版了。"
            }
        }
    }

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private let session: URLSession
    private let cookies: HTTPCookieStorage

    init() {
        // Its own in-memory cookie jar: nothing shared with the rest of the
        // app, nothing written to disk.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        cookies = configuration.httpCookieStorage ?? HTTPCookieStorage()
        session = URLSession(configuration: configuration)
        // Visitor identities last for months: reuse last launch's instead of
        // minting new ones every time.
        for properties in UserDefaults.standard.array(forKey: Self.savedCookiesKey) as? [[String: Any]] ?? [] {
            let keyed = Dictionary(uniqueKeysWithValues: properties.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            if let cookie = HTTPCookie(properties: keyed), let expires = cookie.expiresDate, expires > Date() {
                cookies.setCookie(cookie)
            }
        }
    }

    private static let savedCookiesKey = "weiboVisitorCookies"

    /// Only the visitor identity, and only cookies that carry their own expiry.
    private func saveVisitorCookies() {
        let kept = (cookies.cookies ?? []).filter {
            ["SUB", "SUBP"].contains($0.name) && $0.domain.contains("weibo") && $0.expiresDate != nil
        }
        let plist = kept.compactMap { $0.properties }.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
        UserDefaults.standard.set(plist, forKey: Self.savedCookiesKey)
    }

    // MARK: Endpoints

    /// One page of an uploader's video feed (weibo.com profile "视频" tab).
    func uploaderVideos(uid: String, cursor: String? = nil) async throws -> [String: Any] {
        var components = URLComponents(string: "https://weibo.com/ajax/profile/getWaterFallContent")!
        components.queryItems = [URLQueryItem(name: "uid", value: uid)]
            + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        return try await json(components.url!, site: .com, referer: "https://weibo.com/u/\(uid)")
    }

    /// Video search on m.weibo.cn (the desktop search needs a login).
    func searchVideos(_ query: String) async throws -> [String: Any] {
        var components = URLComponents(string: "https://m.weibo.cn/api/container/getIndex")!
        components.queryItems = [
            URLQueryItem(name: "containerid", value: "100103type=64&q=\(query)"),
            URLQueryItem(name: "page_type", value: "searchall"),
        ]
        // URLComponents leaves "&" and "=" inside a value alone; Weibo wants
        // the containerid encoded as one value.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "100103type=64&q=", with: "100103type%3D64%26q%3D")
        return try await json(components.url!, site: .cn, referer: "https://m.weibo.cn/search")
    }

    /// One post with freshly signed play links.
    func status(_ id: String) async throws -> [String: Any] {
        var components = URLComponents(string: "https://weibo.com/ajax/statuses/show")!
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return try await json(components.url!, site: .com, referer: "https://weibo.com/")
    }

    // MARK: Plumbing

    private func json(_ url: URL, site: Site, referer: String) async throws -> [String: Any] {
        for attempt in 0..<2 {
            if attempt > 0 || !hasVisitor(site) { try await mintVisitor(site) }
            var request = URLRequest(url: url)
            request.setValue(referer, forHTTPHeaderField: "Referer")
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if status == 200 || status == 403 || status == 432 { continue }
                throw Failure.badResponse
            }
            if let ok = root["ok"] as? NSNumber, ok.intValue == -100 { continue }
            if root["error"] != nil, root["data"] == nil, root["mblogid"] == nil { continue }
            return root
        }
        throw Failure.blocked
    }

    private func hasVisitor(_ site: Site) -> Bool {
        (cookies.cookies(for: site.probe) ?? []).contains { $0.name == "SUB" && !$0.value.isEmpty && $0.value != "deleted" }
    }

    /// Weibo's own visitor page does this POST; the answer sets SUB/SUBP.
    private func mintVisitor(_ site: Site) async throws {
        var request = URLRequest(url: site.visitorEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("cb=visitor_gray_callback&tid=&from=weibo&webdriver=false".utf8)
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, hasVisitor(site) else { throw Failure.blocked }
        saveVisitorCookies()
    }
}
