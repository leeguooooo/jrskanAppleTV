import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

/// Every recording on this device: the ones running now and the ones on
/// disk. Deliberately independent of `PlayerSession`: closing the player
/// does not stop a recording, so a Mac (or a phone still playing audio in
/// the background) keeps recording the match nobody is watching.
@MainActor
final class RecordingCenter: ObservableObject {
    static let shared = RecordingCenter()

    /// Newest first; active recordings included, with their latest info.
    @Published private(set) var recordings: [RecordingInfo] = []
    @Published private(set) var active: [String: HLSRecorder] = [:]
    /// MP4 export progress (0…1) for recordings being turned into a video.
    @Published private(set) var exporting: [String: Double] = [:]
    @Published private(set) var exportErrors: [String: String] = [:]

    private let store: RecordingStore
    private let server: RecordingServer
    private var observers: [String: AnyCancellable] = [:]
    private var activity: NSObjectProtocol?
    #if os(iOS)
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(store: RecordingStore = .standard, server: RecordingServer = .shared) {
        self.store = store
        self.server = server
        reload(markingInterrupted: true)
        exportPending()
    }

    // MARK: - Queries

    func recorder(forMatch matchID: String) -> HLSRecorder? {
        active.values.first { $0.info.matchID == matchID && $0.phase != .finished }
    }

    var totalBytes: Int64 { recordings.reduce(0) { $0 + $1.bytes } }

    // MARK: - Commands

    /// Start recording the stream the player has just resolved.
    @discardableResult
    func start(match: LiveMatch, sources: [MatchSource], index: Int, streamURL: URL) -> HLSRecorder? {
        if let existing = recorder(forMatch: match.id) { return existing }
        guard sources.indices.contains(index) else { return nil }
        let info = RecordingInfo(
            id: Self.makeID(),
            matchID: match.id,
            title: "\(match.homeTeam) vs \(match.awayTeam)",
            league: match.league,
            channelName: sources[index].name,
            startedAt: Date()
        )
        guard let folder = try? store.create(info) else { return nil }
        let recorder = HLSRecorder(info: info, folder: folder, streamURL: streamURL, sources: sources, sourceIndex: index)
        recorder.onFinish = { [weak self] recorder in self?.recorderDidFinish(recorder) }
        active[info.id] = recorder
        observers[info.id] = recorder.objectWillChange
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.reload() }
        server.setLive(info.id, true)
        recorder.start()
        updateActivity()
        reload()
        return recorder
    }

    func stop(_ id: String) {
        active[id]?.stop()
    }

    func delete(_ id: String) {
        active[id]?.stop()
        queue.removeAll { $0 == id }
        try? store.delete(id)
        reload()
    }

    /// The finished MP4 when there is one, otherwise the segments over loopback.
    func playbackURL(for info: RecordingInfo) async throws -> URL {
        if let video = store.videoURL(info) { return video }
        return try await server.playlistURL(for: info.id)
    }

    func videoURL(_ info: RecordingInfo) -> URL? { store.videoURL(info) }

    var videosDirectory: URL { store.videos }

    // MARK: - MP4 export

    private var queue: [String] = []
    private var exportTask: Task<Void, Never>?

    /// Finished recordings that still have segments but no MP4 (made before
    /// this existed, or interrupted last time) get one now.
    func exportPending() {
        for info in recordings where info.isFinished && info.videoFile == nil && active[info.id] == nil
            && store.folder(info.id).hasSegments {
            export(info.id)
        }
    }

    func export(_ id: String) {
        guard !queue.contains(id), exporting[id] == nil else { return }
        exportErrors[id] = nil
        queue.append(id)
        runQueue()
    }

    private func runQueue() {
        guard exportTask == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        exportTask = Task { [weak self] in
            await self?.runExport(id)
            self?.exportTask = nil
            self?.runQueue()
        }
    }

    private func runExport(_ id: String) async {
        let folder = store.folder(id)
        guard var info = folder.readInfo(), info.videoFile == nil else { return }
        let segments = folder.segments()
        guard !segments.isEmpty else { return }
        exporting[id] = 0
        #if os(iOS)
        let task = UIApplication.shared.beginBackgroundTask(withName: "recording-export")
        defer { UIApplication.shared.endBackgroundTask(task) }
        #endif
        let config = AppConfigStore.shared
        let overlay = RecordingExporter.Overlay(
            watermark: config.config.visibleWatermark(isMember: config.isMember),
            banner: config.slot("recording_banner"))
        do {
            let output = try store.newVideoURL(named: info.suggestedFileName)
            try await RecordingExporter.export(
                segments: segments, intermediate: folder.url.appendingPathComponent("remux.mp4"),
                output: output, overlay: overlay
            ) { value in
                Task { @MainActor [weak self] in
                    if self?.exporting[id] != nil { self?.exporting[id] = value }
                }
            }
            info.videoFile = output.lastPathComponent
            try folder.writeInfo(info)
            folder.removeMedia()
        } catch {
            exportErrors[id] = error.localizedDescription
        }
        exporting[id] = nil
        reload()
    }

    /// Called from the app's scene phase. With nothing playing iOS suspends
    /// the app within seconds; the extra time lets in-flight segments land
    /// and the info file catch up. Recording resumes, with a gap, on return.
    func appDidEnterBackground() {
        #if os(iOS)
        guard !active.isEmpty, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "recording") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        #endif
    }

    func appWillEnterForeground() {
        #if os(iOS)
        endBackgroundTask()
        #endif
        // An export the system cut short while suspended starts over.
        for id in exportErrors.keys { export(id) }
    }

    // MARK: - Internals

    private func recorderDidFinish(_ recorder: HLSRecorder) {
        active[recorder.id] = nil
        observers[recorder.id] = nil
        server.setLive(recorder.id, false)
        updateActivity()
        reload()
        if recorder.info.segmentCount > 0 { export(recorder.id) }
    }

    private func reload(markingInterrupted: Bool = false) {
        var list = store.list()
        // An MP4 deleted in the Files app, with no segments left: nothing to keep.
        list.removeAll { info in
            guard info.videoFile != nil, store.videoURL(info) == nil, !store.folder(info.id).hasSegments else { return false }
            try? store.delete(info.id)
            return true
        }
        for index in list.indices {
            if let recorder = active[list[index].id] {
                list[index] = recorder.info
            } else if markingInterrupted, !list[index].isFinished {
                // The app quit or crashed mid-recording; the segments are fine.
                list[index].endedAt = list[index].startedAt.addingTimeInterval(list[index].duration)
                list[index].endReason = "应用被关闭，录像已中断"
                try? store.folder(list[index].id).writeInfo(list[index])
            }
        }
        recordings = list
    }

    /// Keeps a Mac from App Napping (which throttles the playlist polling
    /// into missed segments) or idle-sleeping while a recording runs.
    private func updateActivity() {
        if active.isEmpty {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            #if os(iOS)
            endBackgroundTask()
            #endif
        } else if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "正在录制比赛")
        }
    }

    #if os(iOS)
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        for recorder in active.values { recorder.flushInfo() }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    #endif

    private static func makeID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6).lowercased())"
    }
}
