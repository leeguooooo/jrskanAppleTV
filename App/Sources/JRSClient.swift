import Foundation

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
        let homepage = try await fetchText(from: homepageURL)
        guard let scriptURL = listingScriptURL(in: homepage) else {
            throw JRSClientError.missingListingScript
        }
        let script = try await fetchText(from: scriptURL)
        return try parser.parse(script: script, relativeTo: homepageURL)
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
