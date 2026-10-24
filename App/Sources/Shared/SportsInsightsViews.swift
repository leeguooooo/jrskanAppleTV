import AVKit
import Combine
import SwiftUI

struct SportsInsightsSection: View {
    @ObservedObject var model: MatchInsightsModel
    let match: LiveMatch
    let channels: [MatchSource]
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SportsStatsContent(model: model)
            .task(id: "\(scenePhase)-\(channels.map(\.id).joined(separator: ","))") {
                guard scenePhase == .active else { return }
                await model.watch(match: match, channels: channels)
            }
    }
}

struct SportsStatsContent: View {
    @ObservedObject var model: MatchInsightsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("比赛数据与技术统计").font(.headline)
            if let snapshot = model.snapshot {
                HStack {
                    Text("\(snapshot.left)  \(snapshot.score)  \(snapshot.right)").font(.headline.monospacedDigit())
                    Spacer()
                    Text(snapshot.period).font(.subheadline)
                }
                ForEach(Array(snapshot.tables.enumerated()), id: \.offset) { _, table in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(table.title).font(.subheadline.weight(.semibold))
                        if table.title == "球队技术统计" {
                            VStack(spacing: 12) {
                                comparisonRow(table.headers, header: true)
                                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                                    comparisonRow(row, header: false)
                                }
                            }
                            .font(.subheadline.monospacedDigit())
                        } else {
                            ScrollView(.horizontal) {
                                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                                    tableRow(table.headers, header: true)
                                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                                        tableRow(row, header: false)
                                    }
                                }
                                .font(.callout.monospacedDigit())
                                .padding(.vertical, 8)
                            }
                            #if os(tvOS)
                            .focusable()
                            #endif
                            Text("左右滚动查看全部列").font(.caption2).foregroundStyle(Palette.secondaryText)
                        }
                    }
                }
                Text("腾讯体育 · 更新于 \(snapshot.updatedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(Palette.secondaryText)
            }
            if !model.status.isEmpty {
                Text(model.status).font(.subheadline).foregroundStyle(Palette.secondaryText)
            }
            if model.mid != nil {
                Toggle("腾讯体育评论弹幕", isOn: $model.danmakuEnabled)
                    .font(.subheadline)
                Text("实时评论可能快于视频画面，可在播放器中关闭。")
                    .font(.caption).foregroundStyle(Palette.secondaryText)
            }
        }
        .foregroundStyle(Palette.primaryText)
        .padding(20)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func comparisonRow(_ values: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value.replacingOccurrences(of: " (", with: "\n("))
                    .fontWeight(header ? .semibold : .regular)
                    .foregroundStyle(header ? Palette.secondaryText : Palette.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tableRow(_ values: [String], header: Bool) -> some View {
        GridRow {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                Text(value.isEmpty ? "—" : value)
                    .fontWeight(header ? .semibold : .regular)
                    .foregroundStyle(header ? Palette.secondaryText : Palette.primaryText)
                    .frame(minWidth: index == 0 ? 110 : 52, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

struct SportsStatsSheet: View {
    @ObservedObject var model: MatchInsightsModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { SportsStatsContent(model: model).padding(24) }
                .background(Palette.backgroundBottom)
                .navigationTitle("比赛数据")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
    }
}

struct SportsDanmakuOverlay: View {
    @ObservedObject var model: MatchInsightsModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        DanmakuCanvas(comments: model.comments, enabled: model.danmakuEnabled && scenePhase == .active)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: "\(model.mid ?? "")-\(model.danmakuEnabled)-\(scenePhase)") {
                guard scenePhase == .active else { return }
                await model.watchComments()
            }
    }
}

private struct DanmakuCanvas: UIViewRepresentable {
    let comments: [SportsComment]
    let enabled: Bool
    func makeUIView(context: Context) -> DanmakuView { DanmakuView() }
    func updateUIView(_ view: DanmakuView, context: Context) { view.update(comments: comments, enabled: enabled) }
    static func dismantleUIView(_ uiView: DanmakuView, coordinator: ()) { uiView.stop() }
}

/// Three lanes, one new comment every 2.5 seconds, capped at 20 queued texts.
/// View animation is independent of AVPlayer and never receives remote input.
private final class DanmakuView: UIView {
    private var queue: [SportsComment] = []
    private var seen: [String] = []
    private var timer: Timer?
    private var lane = 0
    private var enabled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { timer?.invalidate() }

    func update(comments: [SportsComment], enabled: Bool) {
        self.enabled = enabled
        guard enabled else { stop(); return }
        for comment in comments where !seen.contains(comment.id) {
            queue.append(comment); seen.append(comment.id)
        }
        queue = Array(queue.suffix(20)); seen = Array(seen.suffix(500))
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.emit() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() }
    }

    func stop() {
        timer?.invalidate(); timer = nil; queue = []
        subviews.forEach { $0.layer.removeAllAnimations(); $0.removeFromSuperview() }
    }

    private func emit() {
        guard enabled, window != nil, bounds.width > 100, !queue.isEmpty else { return }
        queue.removeAll { Date().timeIntervalSince($0.postedAt) > 120 }
        guard !queue.isEmpty else { return }
        let label = UILabel()
        label.text = queue.removeFirst().text
        #if os(tvOS)
        label.font = .systemFont(ofSize: 27, weight: .semibold)
        let lineHeight: CGFloat = 42
        #else
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        let lineHeight: CGFloat = 29
        #endif
        label.textColor = .white.withAlphaComponent(0.88)
        label.shadowColor = .black; label.shadowOffset = CGSize(width: 1, height: 1)
        label.sizeToFit()
        // Keep each lane's occupancy under 7.5 seconds, including long texts.
        label.frame.origin = CGPoint(x: bounds.width, y: max(70, bounds.height * 0.17) + CGFloat(lane) * lineHeight)
        lane = (lane + 1) % 3
        addSubview(label)
        UIView.animate(withDuration: 7, delay: 0, options: [.curveLinear, .allowUserInteraction]) {
            label.frame.origin.x = -label.bounds.width
        } completion: { _ in label.removeFromSuperview() }
    }
}
