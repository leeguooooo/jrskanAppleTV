#if DEBUG
import Foundation

/// Debug-only launch argument that jumps straight to a screen, so a page can
/// be checked on a simulator without driving the remote or synthesising taps
/// (both are unreliable from the command line). Release builds do not
/// contain this code.
///
///     xcrun simctl launch <udid> com.leeguoo.jrskan.tv -route play:live
///
/// Routes:
///   detail:<n>      open the n-th match of the current filter
///   play:<n>        open it and start the suggested channel
///   play:live       open the most recently started live match that has
///                   channels and start playing
enum DebugRoute {
    static var raw: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-route"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static var autoplay: Bool { raw?.hasPrefix("play:") ?? false }

    /// The match the route points at, once the list has loaded.
    static func target(in matches: [LiveMatch], now: Date = Date()) -> LiveMatch? {
        guard let raw else { return nil }
        let argument = raw.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        if argument == "live" {
            return matches
                .filter { !$0.sources.isEmpty }
                .compactMap { match -> (LiveMatch, Int)? in
                    if case .live(let elapsed) = MatchSchedule.status(for: match.time, now: now) {
                        return (match, elapsed)
                    }
                    return nil
                }
                .min { $0.1 < $1.1 }?.0
        }
        if let index = Int(argument), matches.indices.contains(index) {
            return matches[index]
        }
        return nil
    }
}
#endif
