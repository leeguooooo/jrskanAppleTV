import AVKit
import SwiftUI

/// Recordings on this device: the ones running now, then finished ones,
/// newest first. Tapping a row plays it, a running one included (it plays
/// as a growing EVENT playlist, so the viewer can scrub back during a
/// match). Recordings stay on this device; nothing is uploaded.
struct RecordingsScreen: View {
    @ObservedObject private var center = RecordingCenter.shared
    @State private var playing: RecordingInfo?
    @State private var playbackError: String?

    var body: some View {
        List {
            let running = center.recordings.filter { center.active[$0.id] != nil }
            let finished = center.recordings.filter { center.active[$0.id] == nil }

            if !running.isEmpty {
                Section("正在录制") {
                    ForEach(running) { info in
                        if let recorder = center.active[info.id] {
                            Button { playing = info } label: { ActiveRecordingRow(recorder: recorder) }
                                .tint(.primary)
                                .swipeActions {
                                    Button("停止") { center.stop(info.id) }.tint(Palette.live)
                                }
                        }
                    }
                }
            }

            if !finished.isEmpty {
                Section {
                    ForEach(finished) { info in
                        let video = center.videoURL(info)
                        Button { playing = info } label: {
                            RecordingRow(info: info, video: video, progress: center.exporting[info.id],
                                         error: center.exportErrors[info.id])
                        }
                        .tint(.primary)
                        .contextMenu {
                            if let video {
                                ShareLink(item: video) { Label("分享", systemImage: "square.and.arrow.up") }
                                Button("在「文件」中显示", systemImage: "folder") { Self.reveal(center.videosDirectory) }
                            } else if center.exportErrors[info.id] != nil {
                                Button("重新生成视频", systemImage: "arrow.clockwise") { center.export(info.id) }
                            }
                            Button("删除", systemImage: "trash", role: .destructive) { center.delete(info.id) }
                        }
                    }
                    .onDelete { offsets in
                        for offset in offsets { center.delete(finished[offset].id) }
                    }
                } header: {
                    Text("已录制")
                } footer: {
                    Text("录完会自动生成带水印的 MP4，存在「文件」App › 我的 iPhone › JRKAN › 录像，点右边的分享按钮就能发出去。录像只保存在本机，不会上传。")
                }

                Section {
                    Button { Self.reveal(center.videosDirectory) } label: {
                        Label("在「文件」中打开录像文件夹", systemImage: "folder")
                    }
                }
            }

            Section {
                Text(Self.backgroundNote)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            } header: {
                Text("后台录制")
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if center.recordings.isEmpty {
                ContentUnavailableView("还没有录像", systemImage: "record.circle",
                    description: Text("播放比赛时点顶部的「录像」，关掉播放器也会继续录。"))
            }
        }
        .navigationTitle("录像")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playing) { info in
            RecordingPlayerScreen(info: info)
        }
        #if DEBUG
        .task {
            if DebugRoute.raw == "recordings:play" { playing = center.recordings.first }
        }
        #endif
    }

    private static var backgroundNote: String {
        if ProcessInfo.processInfo.isMacCatalystApp || ProcessInfo.processInfo.isiOSAppOnMac {
            return "应用开着就会一直录，切到别的窗口或最小化都不影响；退出应用会停止录像。"
        }
        return "播放器在播放时（包括锁屏和画中画）可以在后台继续录。没有在播放时切到后台，iOS 会在几十秒后暂停应用，录像也随之暂停；回到应用后自动接着录，中间会缺一段。"
    }

    /// Opens the Files app (or Finder on a Mac) at the videos folder.
    static func reveal(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.isMacCatalystApp {
            UIApplication.shared.open(directory)
        } else if let url = URL(string: "shareddocuments://" + directory.path) {
            UIApplication.shared.open(url)
        }
    }

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3_600
        let minutes = total / 60 % 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

private struct ActiveRecordingRow: View {
    @ObservedObject var recorder: HLSRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(Palette.live)
                    .symbolEffect(.pulse, isActive: recorder.phase == .recording)
                Text(recorder.info.title).font(.body.weight(.semibold)).lineLimit(1)
            }
            Text("\(recorder.info.league) · \(recorder.info.channelName)")
                .font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(1)
            Text(statusText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(recorder.phase == .reconnecting ? .orange : Palette.secondaryText)
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        let info = recorder.info
        let base = "\(RecordingsScreen.durationText(info.duration)) · \(RecordingsScreen.byteText(info.bytes))"
        return recorder.phase == .reconnecting ? "\(base) · 正在重新连接…" : "\(base) · 录制中"
    }
}

private struct RecordingRow: View {
    let info: RecordingInfo
    let video: URL?
    let progress: Double?
    let error: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(info.league) · \(info.channelName) · \(info.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(1)
                Text(detailText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(error == nil ? Palette.tertiaryText : Color.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let progress {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
            } else if let video {
                ShareLink(item: video) {
                    Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("分享")
            }
        }
        .padding(.vertical, 2)
    }

    private var detailText: String {
        var parts = [RecordingsScreen.durationText(info.duration)]
        if let progress {
            parts.append("正在生成视频 \(Int(progress * 100))%")
        } else if let error {
            parts.append("\(error) 长按可重试")
        } else if let video {
            let size = (try? video.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            parts.append("MP4 · \(RecordingsScreen.byteText(size))")
        } else {
            parts.append(RecordingsScreen.byteText(info.bytes))
        }
        if info.gapCount > 0 { parts.append("\(info.gapCount) 处缺口") }
        if let reason = info.endReason, video == nil, progress == nil { parts.append(reason) }
        return parts.joined(separator: " · ")
    }
}

/// Plays one recording: its MP4 when made, else the segments through the
/// loopback server. Separate from
/// `PlayerSession`, which belongs to the live stream.
private struct RecordingPlayerScreen: View {
    let info: RecordingInfo
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                RecordingPlayerContainer(player: player).ignoresSafeArea()
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Text(errorMessage).foregroundStyle(.white)
                    Button("关闭") { dismiss() }
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            do {
                let url = try await RecordingCenter.shared.playbackURL(for: info)
                // The live player keeps its stream; it just stops talking over this one.
                PlayerSession.shared.player.pause()
                let player = AVPlayer(url: url)
                player.play()
                self.player = player
            } catch {
                errorMessage = "无法打开录像：\(error.localizedDescription)"
            }
        }
        .onAppear { Orientation.enterLandscape() }
        .onDisappear {
            player?.pause()
            Orientation.restoreDefault()
        }
    }
}

private struct RecordingPlayerContainer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}

/// Record button for the player overlay: starts a recording of what is
/// playing, or shows the running one with stop and "record this channel
/// instead" when the viewer has switched channels since it started.
struct RecordControl: View {
    @ObservedObject var model: MatchPlaybackModel
    @ObservedObject private var center = RecordingCenter.shared

    var body: some View {
        if let recorder = center.recorder(forMatch: model.match.id) {
            RunningRecordMenu(recorder: recorder, model: model)
        } else {
            Button {
                guard let playback = model.playback else { return }
                center.start(match: model.match, sources: model.resolvedChannels,
                             index: playback.index, streamURL: playback.url)
            } label: {
                Label("录像", systemImage: "record.circle")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: Capsule())
            }
            .disabled(model.playback == nil)
        }
    }
}

private struct RunningRecordMenu: View {
    @ObservedObject var recorder: HLSRecorder
    @ObservedObject var model: MatchPlaybackModel

    var body: some View {
        Menu {
            if let playing = model.playback, playing.index != recorder.sourceIndex,
               recorder.sources.indices.contains(playing.index) {
                Button("改录当前线路「\(playing.sourceName)」", systemImage: "arrow.triangle.swap") {
                    recorder.switchSource(to: playing.index)
                }
            }
            Button("停止录像", systemImage: "stop.circle", role: .destructive) {
                RecordingCenter.shared.stop(recorder.id)
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(Palette.live).frame(width: 8, height: 8)
                Text(RecordingsScreen.durationText(recorder.info.duration))
                    .monospacedDigit()
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.45), in: Capsule())
        }
        .accessibilityLabel("正在录像，\(RecordingsScreen.durationText(recorder.info.duration))")
    }
}
