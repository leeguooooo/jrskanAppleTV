import AVKit
import AVFoundation
import SwiftUI

struct PlayerScreen: View {
    let match: LiveMatch
    let source: MatchSource

    @State private var player: AVPlayer?
    @State private var isResolving = true
    @State private var errorMessage: String?

    private let resolver = StreamResolver()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea(edges: .bottom)
            } else if isResolving {
                VStack(spacing: 18) {
                    Text("第 3 步 · 正在开始播放")
                        .font(.headline)
                    ProgressView("正在解析 \(source.name)…")
                        .tint(.white)
                }
                .foregroundStyle(.white)
            } else {
                ContentUnavailableView {
                    Label("无法播放此线路", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage ?? "请返回并尝试其他线路。")
                } actions: {
                    Button("重试") {
                        Task { await load() }
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .navigationTitle("播放 · \(source.name)")
        .task(id: source.id) {
            await load()
        }
        .onDisappear {
            player?.pause()
        }
    }

    @MainActor
    private func load() async {
        isResolving = true
        errorMessage = nil
        player?.pause()
        player = nil

        do {
            let streamURL = try await resolver.resolve(sourcePageURL: source.pageURL)
            let newPlayer = AVPlayer(url: streamURL)
            player = newPlayer
            isResolving = false
            newPlayer.play()
        } catch {
            isResolving = false
            errorMessage = error.localizedDescription
        }
    }
}
