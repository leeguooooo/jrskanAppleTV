import Foundation

enum ListingParserError: LocalizedError {
    case noMatches

    var errorDescription: String? {
        switch self {
        case .noMatches:
            return "公开页面当前没有可识别的比赛，或者页面格式已经变化。"
        }
    }
}

struct JRSListingParser {
    func parse(script: String, relativeTo baseURL: URL) throws -> [LiveMatch] {
        let html = decodeDocumentWrites(in: script)
        let blocks = html.regexCaptures(
            #"(?is)(<ul\s+class="item\s+play[^"]*"[^>]*data-lid="([^"]+)"[^>]*>.*?</ul>)"#
        )

        let matches = blocks.compactMap { captures -> LiveMatch? in
            guard captures.count >= 3 else { return nil }
            let block = captures[1]
            let dataID = captures[2]
            let league = firstText(
                in: block,
                pattern: #"(?is)<li\s+class="lab_events"[^>]*>.*?<span\s+class="name">(.+?)</span>"#
            )
            let time = firstText(
                in: block,
                pattern: #"(?is)<li\s+class="lab_time"[^>]*>(.+?)</li>"#
            )
            let teams = block.regexCaptures(
                #"(?is)<li\s+class="lab_team_(?:home|away)"[^>]*>.*?<strong\s+class="name">(.+?)</strong>.*?<img[^>]+src="([^"]*)"#
            )

            guard teams.count >= 2 else { return nil }
            let homeTeam = cleanHTML(teams[0][1])
            let awayTeam = cleanHTML(teams[1][1])
            guard !league.isEmpty, !homeTeam.isEmpty, !awayTeam.isEmpty else { return nil }

            let sources = parseSources(in: block, baseURL: baseURL, matchID: dataID)
            return LiveMatch(
                id: dataID,
                league: league,
                time: time,
                homeTeam: homeTeam,
                awayTeam: awayTeam,
                homeLogoURL: URL(string: cleanHTML(teams[0][2])),
                awayLogoURL: URL(string: cleanHTML(teams[1][2])),
                isHot: block.range(of: #"class="[^"]*\bhot\b"#, options: .regularExpression) != nil,
                sources: sources
            )
        }

        guard !matches.isEmpty else {
            throw ListingParserError.noMatches
        }
        return matches
    }

    private func decodeDocumentWrites(in script: String) -> String {
        script.regexCaptures(#"(?is)document\.write\(\s*'((?:\\'|[^'])*)'\s*\)\s*;?"#)
            .compactMap { $0.count > 1 ? $0[1] : nil }
            .map {
                $0.replacingOccurrences(of: #"\'"#, with: "'", options: .literal)
                    .replacingOccurrences(of: #"\/"#, with: "/", options: .literal)
            }
            .joined(separator: "\n")
    }

    private func parseSources(in block: String, baseURL: URL, matchID: String) -> [MatchSource] {
        let anchors = block.regexCaptures(
            #"(?is)<a\s+([^>]*class="[^"]*\bok\b[^"]*"[^>]*)>(.*?)</a>"#
        )

        var seen = Set<URL>()
        return anchors.enumerated().compactMap { offset, captures in
            guard captures.count >= 3 else { return nil }
            let attributes = captures[1]
            let innerHTML = captures[2]
            let dataPlay = attribute("data-play", in: attributes)
            let href = attribute("href", in: attributes)
            // The public link is the route that can be opened independently.
            // `data-play` is often an older mirror consumed only by site JS.
            let rawURL = [href, dataPlay]
                .compactMap { $0 }
                .first { !$0.isEmpty && !$0.hasPrefix("javascript:") }

            guard
                let rawURL,
                let pageURL = resolve(rawURL, relativeTo: baseURL),
                seen.insert(pageURL).inserted
            else {
                return nil
            }

            let label = firstText(
                in: innerHTML,
                pattern: #"(?is)<strong[^>]*>(.+?)</strong>"#
            )
            return MatchSource(
                id: "\(matchID)-\(offset)-\(pageURL.absoluteString)",
                name: label.isEmpty ? "线路 \(offset + 1)" : label,
                pageURL: pageURL
            )
        }
    }

    private func attribute(_ name: String, in attributes: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        return attributes.regexCaptures(#"\#(escapedName)="([^"]*)""#).first?[safe: 1]
            .map(cleanHTML)
    }

    private func firstText(in text: String, pattern: String) -> String {
        guard let value = text.regexCaptures(pattern).first?[safe: 1] else {
            return ""
        }
        return cleanHTML(value)
    }

    private func cleanHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolve(_ rawValue: String, relativeTo baseURL: URL) -> URL? {
        if rawValue.hasPrefix("//") {
            return URL(string: "https:\(rawValue)")
        }
        return URL(string: rawValue, relativeTo: baseURL)?.absoluteURL
    }
}

extension String {
    func regexCaptures(_ pattern: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(startIndex..., in: self)
        return expression.matches(in: self, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                let captureRange = match.range(at: index)
                guard
                    captureRange.location != NSNotFound,
                    let range = Range(captureRange, in: self)
                else {
                    return ""
                }
                return String(self[range])
            }
        }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
