import SwiftUI

/// Download state for one upload, as a small trailing control: download
/// (asks for the quality, with sizes), progress, or done.
struct ReplayDownloadButton: View {
    let video: ReplayVideo
    var fixture: LiveMatch?
    @ObservedObject private var center = ReplayDownloadCenter.shared
    @State private var choices: [ReplayStream] = []
    @State private var choosing = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        let item = center.item(video.id)
        Button { tapped(item) } label: {
            Group {
                switch item?.phase {
                case .finished:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.healthy)
                case .downloading, .queued:
                    ZStack {
                        Circle().stroke(Palette.hairline, lineWidth: 3)
                        Circle().trim(from: 0, to: center.progress(video.id) ?? 0.02)
                            .stroke(Palette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 20, height: 20)
                case .paused:
                    Image(systemName: "pause.circle").foregroundStyle(Palette.secondaryText)
                case .failed:
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.live)
                case nil:
                    if loading { ProgressView() } else { Image(systemName: "arrow.down.circle").foregroundStyle(Palette.accent) }
                }
            }
            .font(.title3)
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(item == nil ? "下载" : "下载状态")
        .confirmationDialog("下载到本机", isPresented: $choosing, titleVisibility: .visible) {
            ForEach(choices, id: \.label) { stream in
                Button("\(stream.qualityLabel) · \(stream.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "大小未知")") {
                    center.download(video, stream: stream, fixture: fixture)
                }
            }
        } message: {
            Text("\(ReplayDisclaimer.footer)。视频只保存在本应用里，下载时可以切到别的应用，回来会继续。")
        }
        .alert("没法下载", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func tapped(_ item: ReplayDownload?) {
        switch item?.phase {
        case .downloading, .queued: center.pause(video.id)
        case .paused, .failed: center.resume(video.id)
        case .finished: break
        case nil:
            loading = true
            Task {
                defer { loading = false }
                do {
                    let streams: [ReplayStream]
                    if let cached = ReplayCache.usableStreams(for: video.id) {
                        streams = cached
                    } else {
                        streams = ReplayParsing.streams(try await WeiboClient.shared.status(video.id))
                    }
                    ReplayCache.storeStreams(streams, for: video.id)
                    // Smallest first: most people want the lighter copy.
                    choices = streams.sorted { $0.height < $1.height }
                    if choices.isEmpty { error = "这个视频已经看不了了。" } else { choosing = true }
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

/// 已下载: downloads and their progress; a finished one plays offline.
struct ReplayDownloadsScreen: View {
    @ObservedObject private var center = ReplayDownloadCenter.shared
    @ObservedObject private var launcher = ReplayLauncher.shared
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        List {
            if center.items.isEmpty {
                ContentUnavailableView("还没有下载", systemImage: "arrow.down.circle",
                                       description: Text("在回看里点视频右边的下载按钮。"))
                    .listRowBackground(Color.clear)
            }
            if let error = launcher.errorMessage {
                Section { TouchNotice(message: error, tone: .error) }.scoreboardRow()
            }
            Section {
                ForEach(center.items) { item in
                    Button {
                        guard item.phase == .finished else { return }
                        launcher.play([item.video], at: 0, fixture: item.fixture, preferences: preferences)
                    } label: {
                        DownloadRow(item: item)
                    }
                    .tint(.primary)
                    .swipeActions {
                        Button("删除", role: .destructive) { center.delete(item.id) }
                    }
                    .contextMenu {
                        Button("删除", systemImage: "trash", role: .destructive) { center.delete(item.id) }
                    }
                }
            } footer: {
                Text("共占用 \(ByteCountFormatter.string(fromByteCount: center.usedBytes, countStyle: .file))。\(ReplayDisclaimer.footer)；视频只保存在本应用里，研究学习完请及时删除。切到后台时系统可能放慢下载，回到应用会继续。")
            }
            .scoreboardRow()
        }
        .listStyle(.insetGrouped)
        .scoreboardList()
        .navigationTitle("已下载")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DownloadRow: View {
    let item: ReplayDownload
    @ObservedObject private var center = ReplayDownloadCenter.shared

    var body: some View {
        HStack(spacing: 12) {
            ReplayCover(url: item.video.coverURL).frame(width: 96, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.video.displayTitle).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(item.video.author) · \(ReplayVideo.durationText(item.video.duration))")
                    .font(.caption).foregroundStyle(Palette.secondaryText).lineLimit(1)
                Text(status).font(.caption.monospacedDigit())
                    .foregroundStyle(item.phase == .failed ? Palette.live : Palette.tertiaryText).lineLimit(2)
                if item.phase == .downloading || item.phase == .queued {
                    ProgressView(value: center.progress(item.id) ?? 0).tint(Palette.accent)
                }
            }
            Spacer(minLength: 0)
            ReplayDownloadButton(video: item.video, fixture: item.fixture)
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        let total = item.totalBytes ?? item.expectedBytes
        let done = center.liveBytes[item.id] ?? item.receivedBytes
        let sizes = total.map { "\(bytes(done)) / \(bytes($0))" } ?? bytes(done)
        switch item.phase {
        case .finished: return "已下载 · \(bytes(item.receivedBytes)) · 点一下离线播放"
        case .downloading: return "正在下载 · \(sizes)"
        case .queued: return "排队中 · \(sizes)"
        case .paused: return "已暂停 · \(sizes) · 点右边继续"
        case .failed: return "\(item.message ?? "下载失败") · 点右边重试"
        }
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
