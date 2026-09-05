import Foundation
import JavaScriptCore

enum StreamResolverError: LocalizedError {
    case noPlayableStream
    case invalidResponse
    case tooManyRedirects

    var errorDescription: String? {
        switch self {
        case .noPlayableStream:
            return "这条线路没有暴露 Apple 原生播放器可用的 HLS 地址。"
        case .invalidResponse:
            return "线路页面暂时无法访问。"
        case .tooManyRedirects:
            return "线路嵌套层级异常，已停止继续解析。"
        }
    }
}

struct StreamResolver {
    let session: URLSession
    let maximumDepth: Int

    init(session: URLSession = .shared, maximumDepth: Int = 6) {
        self.session = session
        self.maximumDepth = maximumDepth
    }

    func resolve(sourcePageURL: URL) async throws -> URL {
        var visited = Set<URL>()
        return try await resolve(
            pageURL: sourcePageURL,
            referer: JRSClient.defaultHomepage,
            depth: 0,
            visited: &visited
        )
    }

    func extractM3U8URL(in html: String, pageURL: URL) -> URL? {
        let decoded = decodeHTMLEntities(html)
        let directPatterns = [
            #"(?i)(https?://[^"'<>\\\s]+\.m3u8[^"'<>\\\s]*)"#,
            #"(?i)(//[^"'<>\\\s]+\.m3u8[^"'<>\\\s]*)"#
        ]

        for pattern in directPatterns {
            if let url = decoded.regexCaptures(pattern)
                .compactMap({ $0[safe: 1] })
                .compactMap({ makeURL(from: $0, relativeTo: pageURL) })
                .first(where: isM3U8URL)
            {
                return url
            }
        }

        // Some player wrappers build the stream as a fixed host plus the
        // current page's `id` query value.
        let hostPatterns = [
            #"(?is)var\s+purl\s*=\s*["'](//[^"']+)["']\s*\+\s*id"#,
            #"(?is)(?:const|var)\s+\w*[Uu]rl\s*=\s*["'](//[^"']+)["']\s*\+\s*id"#
        ]
        guard
            let components = URLComponents(url: pageURL, resolvingAgainstBaseURL: true),
            let streamPath = components.queryItems?.first(where: { $0.name == "id" })?.value,
            streamPath.localizedCaseInsensitiveContains(".m3u8")
        else {
            return nil
        }

        for pattern in hostPatterns {
            guard let host = decoded.regexCaptures(pattern).first?[safe: 1] else {
                continue
            }
            if let url = makeURL(from: host + streamPath, relativeTo: pageURL) {
                return url
            }
        }
        return nil
    }

    func iframeURLs(in html: String, pageURL: URL) -> [URL] {
        let decoded = decodeHTMLEntities(html)
        var urls = decoded.regexCaptures(#"(?is)<iframe[^>]+src\s*=\s*["']([^"']+)["']"#)
            .compactMap { $0[safe: 1] }
            .filter { !$0.hasSuffix("/play/") }
            .compactMap { makeURL(from: $0, relativeTo: pageURL) }

        let buildsPlayerPath = decoded.range(
            of: #"(?is)src\s*=\s*['"]/play/['"]\s*\+\s*id1\s*\+\s*['"]\.html"#,
            options: .regularExpression
        ) != nil
        if
            buildsPlayerPath,
            let components = URLComponents(url: pageURL, resolvingAgainstBaseURL: true),
            let id = components.queryItems?.first(where: { $0.name == "id" })?.value,
            id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
            let dynamicURL = URL(string: "/play/\(id).html", relativeTo: pageURL)?.absoluteURL
        {
            urls.append(dynamicURL)
        }
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    private func resolve(
        pageURL: URL,
        referer: URL,
        depth: Int,
        visited: inout Set<URL>
    ) async throws -> URL {
        guard depth <= maximumDepth else {
            throw StreamResolverError.tooManyRedirects
        }
        if pageURL.path.lowercased().contains(".m3u8") {
            return pageURL
        }
        guard visited.insert(pageURL).inserted else {
            throw StreamResolverError.noPlayableStream
        }

        let html = try await fetchText(from: pageURL, referer: referer)
        if let streamURL = extractM3U8URL(in: html, pageURL: pageURL) {
            return streamURL
        }

        if let streamURL = try await encryptedHLSURL(in: html, pageURL: pageURL) {
            return streamURL
        }

        var nestedPlayerURLs = iframeURLs(in: html, pageURL: pageURL)
        if
            let generatedPlayerURL = try await generatedIframeURL(in: html, pageURL: pageURL),
            !nestedPlayerURLs.contains(generatedPlayerURL)
        {
            nestedPlayerURLs.append(generatedPlayerURL)
        }

        for iframeURL in nestedPlayerURLs {
            do {
                return try await resolve(
                    pageURL: iframeURL,
                    referer: pageURL,
                    depth: depth + 1,
                    visited: &visited
                )
            } catch StreamResolverError.noPlayableStream {
                continue
            }
        }
        throw StreamResolverError.noPlayableStream
    }

    func generatedIframeURL(
        in html: String,
        playerScript: String,
        pageURL: URL
    ) -> URL? {
        guard
            let encodedValue = html.regexCaptures(
                #"(?is)var\s+encodedStr\s*=\s*[\"']([^\"']+)[\"']"#
            ).first?[safe: 1],
            let context = JSContext()
        else {
            return nil
        }

        context.setObject(encodedValue, forKeyedSubscript: "encodedStr" as NSString)
        context.evaluateScript(
            #"""
            var __playerElement = { innerHTML: "" };
            var navigator = { userAgent: "iPhone" };
            var document = {
              getElementById: function() { return __playerElement; }
            };
            """#
        )
        context.evaluateScript(playerScript)
        guard
            context.exception == nil,
            let generatedHTML = context.objectForKeyedSubscript("__playerElement")?
                .objectForKeyedSubscript("innerHTML")?.toString()
        else {
            return nil
        }
        return iframeURLs(in: generatedHTML, pageURL: pageURL).first
    }

    func evaluateEncryptedHLSURL(
        libraryScript: String,
        pageScript: String,
        pageURL: URL
    ) -> URL? {
        guard let context = JSContext() else { return nil }
        context.setObject(pageURL.absoluteString, forKeyedSubscript: "__pageURL" as NSString)
        context.evaluateScript(
            #"""
            var window = this;
            var self = this;
            var document = {
              location: { href: __pageURL },
              referrer: "",
              cookie: "",
              getElementById: function() { return { innerHTML: "" }; },
              write: function() {}
            };
            var navigator = { userAgent: "iPhone", maxTouchPoints: 0 };
            var console = {
              log: function() {}, error: function() {}, warn: function() {},
              info: function() {}, debug: function() {}, exception: function() {},
              trace: function() {}
            };
            var setInterval = function() { return 0; };
            var setTimeout = function() { return 0; };
            var clearInterval = function() {};
            var clearTimeout = function() {};
            """#
        )
        context.evaluateScript(libraryScript)
        guard context.exception == nil else { return nil }
        context.evaluateScript(pageScript)
        guard context.exception == nil else { return nil }
        guard
            let rawValue = context.evaluateScript(
                "decryptUrlWithExpiry(encryptedBase64Str)"
            )?.toString(),
            let streamURL = URL(string: rawValue),
            isM3U8URL(streamURL)
        else {
            return nil
        }
        return streamURL
    }

    private func generatedIframeURL(in html: String, pageURL: URL) async throws -> URL? {
        guard
            html.range(of: "encodedStr") != nil,
            let rawScriptURL = html.regexCaptures(
                #"(?is)<script[^>]+src\s*=\s*[\"']([^\"']*pjs\.js[^\"']*)[\"']"#
            ).first?[safe: 1],
            let scriptURL = makeURL(from: rawScriptURL, relativeTo: pageURL)
        else {
            return nil
        }
        let playerScript = try await fetchText(from: scriptURL, referer: pageURL)
        return generatedIframeURL(in: html, playerScript: playerScript, pageURL: pageURL)
    }

    private func encryptedHLSURL(in html: String, pageURL: URL) async throws -> URL? {
        let pageScript = html.regexCaptures(
            #"(?is)<script(?:\s[^>]*)?>(.*?)</script>"#
        )
        .compactMap { $0[safe: 1] }
        .first { $0.range(of: "decryptUrlWithExpiry") != nil }

        guard
            html.range(of: "decryptUrlWithExpiry") != nil,
            let rawLibraryURL = html.regexCaptures(
                #"(?is)<script[^>]+src\s*=\s*[\"']([^\"']*index\.min\.js[^\"']*)[\"']"#
            ).first?[safe: 1],
            let libraryURL = makeURL(from: rawLibraryURL, relativeTo: pageURL),
            let pageScript
        else {
            return nil
        }

        let libraryScript = try await fetchText(from: libraryURL, referer: pageURL)
        return evaluateEncryptedHLSURL(
            libraryScript: libraryScript,
            pageScript: pageScript,
            pageURL: pageURL
        )
    }

    private func fetchText(from url: URL, referer: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(JRSClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<400).contains(httpResponse.statusCode)
        else {
            throw StreamResolverError.invalidResponse
        }

        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return text
        }
        throw StreamResolverError.invalidResponse
    }

    private func makeURL(from rawValue: String, relativeTo pageURL: URL) -> URL? {
        let cleaned = rawValue
            .replacingOccurrences(of: #"\/"#, with: "/", options: .literal)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("//") {
            return URL(string: "https:\(cleaned)")
        }
        return URL(string: cleaned, relativeTo: pageURL)?.absoluteURL
    }

    private func isM3U8URL(_ url: URL) -> Bool {
        url.path.localizedCaseInsensitiveContains(".m3u8")
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
