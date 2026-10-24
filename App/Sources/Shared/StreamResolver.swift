import Foundation
import JavaScriptCore

enum StreamResolverError: LocalizedError {
    case noPlayableStream
    case invalidResponse
    case tooManyRedirects
    case unavailableStream

    var errorDescription: String? {
        switch self {
        case .noPlayableStream:
            return "这条线路暂未提供可播放的视频。"
        case .invalidResponse:
            return "线路页面暂时无法访问。"
        case .tooManyRedirects:
            return "线路嵌套层级异常，已停止继续解析。"
        case .unavailableStream:
            return "视频源暂不可用或尚未开播，请尝试其他线路。"
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
        extractM3U8URLs(in: html, pageURL: pageURL).first
    }

    private func extractM3U8URLs(in html: String, pageURL: URL) -> [URL] {
        let decoded = decodeHTMLEntities(html)
        if let restoredURL = restoredPlayerURL(in: decoded, pageURL: pageURL) {
            return [restoredURL]
        }
        let directPatterns = [
            #"(?i)(?:src|file|url|m3u8Url)\s*[:=]\s*["']([^"'<>\s]+\.m3u8[^"'<>\s]*)["']"#,
            #"(?i)(https?://[^"'<>\\\s]+\.m3u8[^"'<>\\\s]*)"#,
            #"(?i)(//[^"'<>\\\s]+\.m3u8[^"'<>\\\s]*)"#
        ]

        var candidates: [URL] = []
        for pattern in directPatterns {
            candidates += decoded.regexCaptures(pattern)
                .compactMap({ $0[safe: 1] })
                .compactMap({ makeURL(from: $0, relativeTo: pageURL) })
                .filter(isM3U8URL)
        }
        var seen = Set<URL>()
        candidates = candidates.filter { seen.insert($0).inserted }
        if !candidates.isEmpty { return candidates }

        // Some player wrappers build the stream as a fixed host plus the
        // current page's `id` query value.
        let hostPatterns = [
            #"(?is)(?:const|let|var)\s+\w*[Uu]rl\s*=\s*["']((?:https?:)?//[^"']+)["']\s*\+\s*id"#
        ]
        guard
            let components = URLComponents(url: pageURL, resolvingAgainstBaseURL: true),
            let query = components.percentEncodedQuery,
            let idRange = query.range(of: #"(?:^|&)id="#, options: .regularExpression),
            let streamPath = String(query[idRange.upperBound...]).removingPercentEncoding,
            streamPath.localizedCaseInsensitiveContains(".m3u8")
        else {
            return []
        }

        for pattern in hostPatterns {
            guard let host = decoded.regexCaptures(pattern).first?[safe: 1] else {
                continue
            }
            if let url = makeURL(from: host + streamPath, relativeTo: pageURL) {
                return [url]
            }
        }
        return []
    }

    /// The msss wrapper reverses the second-level domain in its `id` value.
    /// Match that specific player contract rather than treating every wrapper
    /// query containing .m3u8 as media (or reversing ordinary stream hosts).
    private func restoredPlayerURL(in html: String, pageURL: URL) -> URL? {
        guard
            html.range(of: #"\brestoreStreamUrl\s*\(\s*id\s*\)"#, options: .regularExpression) != nil,
            html.range(of: #"\.split\(\s*["']["']\s*\)\s*\.reverse\(\s*\)\s*\.join\(\s*["']["']\s*\)"#,
                       options: .regularExpression) != nil,
            let query = URLComponents(url: pageURL, resolvingAgainstBaseURL: true)?.percentEncodedQuery,
            let idRange = query.range(of: #"(?:^|&)id="#, options: .regularExpression)
        else { return nil }

        // J_get consumes the entire suffix, including unescaped '&' and '='
        // belonging to the media URL's signed query. Decode it exactly once.
        let rawValue = String(query[idRange.upperBound...])
        let value = rawValue.removingPercentEncoding ?? rawValue
        guard
            let url = makeURL(from: value, relativeTo: pageURL),
            isM3U8URL(url),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
            let host = components.host,
            value.hasPrefix("//") || value.lowercased().hasPrefix("https://")
                || value.lowercased().hasPrefix("http://")
        else { return nil }

        var labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        labels[labels.count - 2] = String(labels[labels.count - 2].reversed())
        components.host = labels.joined(separator: ".")
        // The wrapper returns a protocol-relative URL even for an http input.
        components.scheme = "https"
        return components.url
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
        try Task.checkCancellation()
        if isM3U8URL(pageURL) {
            return try await validateStream(pageURL)
        }
        guard visited.insert(pageURL).inserted else {
            throw StreamResolverError.noPlayableStream
        }

        let (html, effectiveURL) = try await fetchPage(from: pageURL, referer: referer)
        if html.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
            guard hasMediaEntries(html) else { throw StreamResolverError.unavailableStream }
            return effectiveURL
        }
        var lastError: Error = StreamResolverError.noPlayableStream
        for streamURL in extractM3U8URLs(in: html, pageURL: effectiveURL) {
            do { return try await validateStream(streamURL) }
            catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        do {
            if let streamURL = try await encryptedHLSURL(in: html, pageURL: effectiveURL) {
                return try await validateStream(streamURL)
            }
        } catch {
            try Task.checkCancellation()
            lastError = error
        }

        var nestedPlayerURLs = iframeURLs(in: html, pageURL: effectiveURL)
        do {
            if let generatedPlayerURL = try await generatedIframeURL(in: html, pageURL: effectiveURL),
               !nestedPlayerURLs.contains(generatedPlayerURL) {
                nestedPlayerURLs.append(generatedPlayerURL)
            }
        } catch {
            try Task.checkCancellation()
            lastError = error
        }

        for iframeURL in nestedPlayerURLs {
            do {
                return try await resolve(
                    pageURL: iframeURL,
                    referer: effectiveURL,
                    depth: depth + 1,
                    visited: &visited
                )
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }

    func generatedIframeURL(in html: String, playerScript: String, pageURL: URL) -> URL? {
        playerScriptResult(in: html, playerScript: playerScript, pageURL: pageURL).url
    }

    /// A fresh, network-free JS environment for each pass. Requests are executed
    /// by URLSession only after native URL validation; scripts never get a bridge
    /// to Foundation, application storage, or the user's cookies.
    func playerScriptResult(in html: String, playerScript: String, pageURL: URL,
                            responses: [String] = []) -> (url: URL?, requests: [URL]) {
        guard playerScript.utf8.count <= 512_000, let context = JSContext() else { return (nil, []) }
        let encoded = html.regexCaptures(#"(?is)var\s+encodedStr\s*=\s*["']([^"']+)["']"#).first?[safe: 1]
        let config = html.regexCaptures(#"(?is)playerUrlBase64\s*:\s*["']([^"']+)["']"#).first?[safe: 1]
        let payload = html.regexCaptures(#"(?is)["']en_str["']\s*:\s*["']([^"']+)["']"#).first?[safe: 1]
        guard encoded != nil || payload != nil else { return (nil, []) }
        context.setObject(pageURL.absoluteString, forKeyedSubscript: "__pageURL" as NSString)
        context.setObject(responses, forKeyedSubscript: "__responses" as NSString)
        context.setObject(encoded ?? "", forKeyedSubscript: "encodedStr" as NSString)
        context.setObject(["playerUrlBase64": config ?? ""], forKeyedSubscript: "playerConfig" as NSString)
        context.setObject(["en_str": payload ?? ""], forKeyedSubscript: "playerData" as NSString)
        let decode: @convention(block) (String) -> String? = { value in
            guard let data = Data(base64Encoded: value) else { return nil }
            return String(data: data, encoding: .isoLatin1)
        }
        let encode: @convention(block) (String) -> String? = { value in
            value.data(using: .isoLatin1)?.base64EncodedString()
        }
        context.setObject(decode, forKeyedSubscript: "atob" as NSString)
        context.setObject(encode, forKeyedSubscript: "btoa" as NSString)
        context.evaluateScript(Self.playerPrelude)
        context.evaluateScript(playerScript)
        guard context.exception == nil else { return (nil, []) }
        let frames = context.objectForKeyedSubscript("__frames")?.toArray() as? [String] ?? []
        let written = context.objectForKeyedSubscript("__container")?.objectForKeyedSubscript("innerHTML")?.toString() ?? ""
        let url = frames.compactMap { makeURL(from: $0, relativeTo: pageURL) }.first
            ?? iframeURLs(in: written, pageURL: pageURL).first
        let requests = (context.objectForKeyedSubscript("__requests")?.toArray() as? [String] ?? [])
            .compactMap { URL(string: $0) }
        return (url, requests)
    }

    private static let playerPrelude = #"""
    var window = this, self = this;
    var __frames = [], __requests = [];
    var __container = {
      innerHTML: '', textContent: '',
      appendChild: function(node) { if (node.src) __frames.push(node.src); },
      replaceChildren: function(node) { this.appendChild(node); }
    };
    var document = {
      location: {href: __pageURL}, referrer: '', cookie: '',
      getElementById: function() { return __container; },
      createElement: function() { return {style:{}, setAttribute:function(k,v) {this[k]=v;}}; },
      write: function() {}
    };
    var navigator = {userAgent:'iPhone',maxTouchPoints:0};
    var console = {log:function(){},error:function(){},warn:function(){},info:function(){},debug:function(){},exception:function(){},trace:function(){}};
    var setTimeout=function(){return 0},setInterval=setTimeout,clearTimeout=function(){},clearInterval=clearTimeout;
    var TextEncoder=function(){};
    TextEncoder.prototype.encode=function(text){var s=unescape(encodeURIComponent(text));return Uint8Array.from(s,function(c){return c.charCodeAt(0);});};
    var TextDecoder=function(){};
    TextDecoder.prototype.decode=function(bytes){var s='';for(var i=0;i<bytes.length;i++) s+=String.fromCharCode(bytes[i]);return decodeURIComponent(escape(s));};
    var crypto={getRandomValues:function(bytes){for(var i=0;i<bytes.length;i++) bytes[i]=Math.floor(Math.random()*256);return bytes;}};
    var URLSearchParams=function(values){this.values=values;};
    URLSearchParams.prototype.toString=function(){var v=this.values;return Object.keys(v).map(function(k){return encodeURIComponent(k)+'='+encodeURIComponent(v[k]);}).join('&');};
    var URL=function(value){var m=/^(https?):\/\/([^\/?#]+)([^#]*)(#.*)?$/i.exec(value);if(!m)throw Error('Invalid URL');this.hostname=m[2];this.username='';this.password='';this.hash=m[4]||'';if(m[2].indexOf('@')>=0)this.username='invalid';};
    // Only record requests here. Native code validates and fetches the supported API.
    // No AbortController: the page skips speculative media probes and selects its fallback URL.
    var fetch=function(url){var i=__requests.length;__requests.push(String(url));if(i>=__responses.length)return new Promise(function(){});var data=JSON.parse(__responses[i]);return Promise.resolve({ok:true,status:200,json:function(){return Promise.resolve(data);}});};
    """#

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
        let isDataPlayer = html.range(of: #"["']en_str["']\s*:"#, options: .regularExpression) != nil
        guard html.contains("encodedStr") || isDataPlayer else { return nil }
        let scripts = html.regexCaptures(#"(?is)<script[^>]+src\s*=\s*["']([^"']+)["']"#)
            .compactMap { $0[safe: 1] }
        let rawScript = scripts.first { raw in
            guard let url = makeURL(from: raw, relativeTo: pageURL) else { return false }
            return url.lastPathComponent == "pjs.js"
                || (isDataPlayer && url.host == "im-imgs-bucket.oss-accelerate.aliyuncs.com"
                    && url.path.hasSuffix(".js") && url.lastPathComponent.count > 20)
        }
        guard let rawScript, let scriptURL = makeURL(from: rawScript, relativeTo: pageURL) else { return nil }
        let script = try await fetchText(from: scriptURL, referer: pageURL)
        var responses: [String] = []
        for _ in 0..<2 {
            try Task.checkCancellation()
            let savedResponses = responses
            let result = await Task.detached(priority: .userInitiated) {
                playerScriptResult(in: html, playerScript: script, pageURL: pageURL, responses: savedResponses)
            }.value
            try Task.checkCancellation()
            if let url = result.url { return url }
            guard responses.isEmpty, let request = result.requests.first,
                  request.scheme == "https", request.host == "infozb6.video.qq.com",
                  request.port == nil, request.user == nil, request.password == nil,
                  request.path == "/cgi-bin/getliveinfo" else { return nil }
            responses.append(try await fetchText(from: request, referer: pageURL))
        }
        return nil
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
        try await fetchPage(from: url, referer: referer).0
    }

    private func fetchPage(from url: URL, referer: URL) async throws -> (String, URL) {
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
            return (text, response.url ?? url)
        }
        if let text = String(data: data, encoding: .isoLatin1) {
            return (text, response.url ?? url)
        }
        throw StreamResolverError.invalidResponse
    }

    /// Reject an expired URL or HTML error page before opening a black player.
    /// Successful parsing alone says nothing about the origin's availability.
    private func validateStream(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8),
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U"),
              hasMediaEntries(text)
        else { throw StreamResolverError.unavailableStream }
        return response.url ?? url
    }

    private func hasMediaEntries(_ text: String) -> Bool {
        text.contains("#EXTINF:") || text.contains("#EXT-X-STREAM-INF:") || text.contains("#EXT-X-PART:")
    }

    private func makeURL(from rawValue: String, relativeTo pageURL: URL) -> URL? {
        let cleaned = rawValue
            .replacingOccurrences(of: #"\/"#, with: "/", options: .literal)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("//") {
            return URL(string: "https:\(cleaned)")
        }
        guard let url = URL(string: cleaned, relativeTo: pageURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func isM3U8URL(_ url: URL) -> Bool {
        url.path.lowercased().hasSuffix(".m3u8")
    }

    private func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\u0026"#, with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
