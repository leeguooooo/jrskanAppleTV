import Foundation
import AVFoundation
import Combine

/// AVPlayer also becomes paused at an item's end. Observe that separately so
/// a stopped live stream is not mistaken for the viewer pressing Pause.
final class PlaybackEndObserver: ObservableObject {
    private var tokens: [NSObjectProtocol] = []
    private var generation = 0

    func observe(_ item: AVPlayerItem, onEnd: @escaping () -> Void) {
        stop()
        let current = generation
        for name in [AVPlayerItem.didPlayToEndTimeNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
                guard self?.generation == current else { return }
                onEnd()
            })
        }
    }

    func stop() {
        generation += 1
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens = []
    }

    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}

/// Samples media progress throughout playback. A paused player is not a stall.
///
/// On a weak network the picture freezes while segments still trickle in.
/// Giving up on that channel only trades it for another one on the same slow
/// network, so while the buffer keeps growing the monitor waits longer before
/// calling the stream dead.
struct PlaybackHealthMonitor {
    enum Event: Equatable {
        case confirmed(startupSeconds: TimeInterval)
        case stalled
    }

    private var lastSample: TimeInterval
    private var lastProgress: TimeInterval
    private var lastMediaTime: Double?
    private var lastBuffered: Double?
    private var lastDataArrival: TimeInterval
    private var activeElapsed: TimeInterval = 0
    private var firstFrameElapsed: TimeInterval?
    private var stablePlayback: TimeInterval = 0
    private var wasAdvancing = false
    private(set) var confirmed = false
    private var failed = false
    var startupTimeout: TimeInterval = 20
    var stallTimeout: TimeInterval = 12
    /// How long a stream that is still downloading may go without a picture.
    var slowNetworkTimeout: TimeInterval = 45

    init(now: TimeInterval) {
        lastSample = now
        lastProgress = now
        lastDataArrival = now
    }

    /// `buffered` is the end of the loaded media ranges, if known.
    mutating func sample(now: TimeInterval, mediaTime: Double, playing: Bool,
                         paused: Bool, ready: Bool, itemFailed: Bool, buffered: Double? = nil) -> Event? {
        guard !failed else { return nil }
        let delta = max(0, now - lastSample)
        lastSample = now
        if itemFailed { failed = true; return .stalled }
        if let buffered, buffered.isFinite {
            if let last = lastBuffered, buffered - last > 0.1 { lastDataArrival = now }
            lastBuffered = buffered
        }
        if paused {
            lastProgress = now
            lastMediaTime = mediaTime.isFinite ? mediaTime : nil
            stablePlayback = 0
            wasAdvancing = false
            return nil
        }
        activeElapsed += delta
        let advancing = mediaTime.isFinite && lastMediaTime.map { abs(mediaTime - $0) > 0.05 } == true
        if mediaTime.isFinite { lastMediaTime = mediaTime }
        if playing && ready && advancing {
            lastProgress = now
            stablePlayback = wasAdvancing ? stablePlayback + min(delta, 1) : 0
            wasAdvancing = true
            if firstFrameElapsed == nil { firstFrameElapsed = activeElapsed }
            if !confirmed && stablePlayback >= 2 {
                confirmed = true
                return .confirmed(startupSeconds: firstFrameElapsed ?? activeElapsed)
            }
        } else {
            stablePlayback = 0
            wasAdvancing = false
        }
        let downloading = now - lastDataArrival < stallTimeout
        let waited = firstFrameElapsed == nil ? activeElapsed : now - lastProgress
        let limit = firstFrameElapsed == nil ? startupTimeout : stallTimeout
        if waited >= limit && (!downloading || waited >= slowNetworkTimeout) {
            failed = true
            return .stalled
        }
        return nil
    }
}
