import AVKit
import Combine
import SwiftUI

/// Kept on the match route, independent of whether the data panel is open.
struct SportsInsightsLifecycle: ViewModifier {
    @ObservedObject var model: MatchInsightsModel
    let match: LiveMatch
    let channels: [MatchSource]
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content.task(id: "\(scenePhase)-\(channels.map(\.id).joined(separator: ","))") {
            guard scenePhase == .active else { return }
            await model.watch(match: match, channels: channels)
        }
    }
}

private enum SportsDataTab: String, CaseIterable {
    case overview = "本场概况"
    case players = "技术统计"
}

private enum SportsDataStyle {
    static let left = Color(red: 0.24, green: 0.53, blue: 1)
    static let right = Color(red: 1, green: 0.65, blue: 0.29)
    static let line = Color.white.opacity(0.09)
    #if os(tvOS)
    static let rowHeight: CGFloat = 58
    static let playerWidth: CGFloat = 210
    static let cellWidth: CGFloat = 94
    #else
    static let rowHeight: CGFloat = 44
    static let playerWidth: CGFloat = 116
    static let cellWidth: CGFloat = 60
    #endif
}

/// Values are parsed only for the comparison bars; the provider's original
/// strings remain the visible source of truth, including zero and missing data.
struct SportsStatComparison {
    let left: Double
    let right: Double
    init?(row: [String]) {
        func number(_ text: String?) -> Double? {
            guard let text, let match = text.regexCaptures(#"^\s*([0-9]+(?:\.[0-9]+)?)"#).first?[safe: 1],
                  let value = Double(match), value.isFinite else { return nil }
            return value
        }
        guard let left = number(row[safe: 1]), let right = number(row[safe: 2]) else { return nil }
        self.left = left; self.right = right
    }
    var leftShare: Double { left + right == 0 ? 0.5 : left / (left + right) }
}

struct SportsStatsContent: View {
    @ObservedObject var model: MatchInsightsModel
    @State private var tab: SportsDataTab = .overview
    @State private var selectedTeam = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: verticalSizeClass == .compact ? 16 : 24) {
            if let snapshot = model.snapshot {
                scoreboard(snapshot)
                if let source = snapshot.scoreSourceName, source != snapshot.sourceName {
                    Text("比分来源：\(source)").font(.caption).foregroundStyle(Palette.secondaryText)
                }
                tabBar
                if tab == .overview {
                    if let periods = snapshot.periodTable { periodScores(periods); tableSource(periods) }
                    if let comparison = snapshot.comparisonTable { teamComparison(comparison, snapshot: snapshot); tableSource(comparison) }
                    if snapshot.periodTable == nil && snapshot.comparisonTable == nil { noStatistics }
                } else {
                    playerStatistics(snapshot)
                }
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text("\(snapshot.sourceName)  \(snapshot.updatedAt.formatted(date: .omitted, time: .standard)) 更新")
                }
                .font(.caption).foregroundStyle(Palette.secondaryText)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(SportsDataStyle.left)
                    Text(model.status).font(.subheadline).foregroundStyle(Palette.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            }
            if model.snapshot != nil && !model.status.isEmpty {
                Label(model.status, systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(Palette.secondaryText)
            }
        }
        #if DEBUG
        .onAppear { if CommandLine.arguments.contains("-stats-players") { tab = .players } }
        #endif
        .foregroundStyle(Palette.primaryText)
        .frame(maxWidth: 1200)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func tableSource(_ table: SportsTable) -> some View {
        if !table.sourceName.isEmpty { Text("来源：\(table.sourceName)").font(.caption).foregroundStyle(Palette.secondaryText) }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(SportsDataTab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    VStack(spacing: 12) {
                        Text(item.rawValue).font(.headline)
                        Capsule().fill(tab == item ? SportsDataStyle.left : .clear).frame(width: 56, height: 3)
                    }
                    .foregroundStyle(tab == item ? SportsDataStyle.left : Palette.secondaryText)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                #if os(tvOS)
                .buttonStyle(.bordered)
                #else
                .buttonStyle(.plain)
                #endif
                .accessibilityAddTraits(tab == item ? [.isSelected] : [])
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(SportsDataStyle.line).frame(height: 1) }
    }

    private func scoreboard(_ snapshot: SportsSnapshot) -> some View {
        let scores = snapshot.score.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        return Group {
        if verticalSizeClass == .compact {
            HStack(spacing: 10) {
                TeamCrest(url: snapshot.leftBadge, teamName: snapshot.left, size: 26)
                Text(snapshot.left).font(.subheadline)
                Text(scores[safe: 0] ?? "—").font(.title2.monospacedDigit().bold()).foregroundStyle(SportsDataStyle.left)
                Spacer(minLength: 8)
                Text(snapshot.period).font(.caption).foregroundStyle(Palette.secondaryText)
                Spacer(minLength: 8)
                Text(scores[safe: 1] ?? "—").font(.title2.monospacedDigit().bold()).foregroundStyle(SportsDataStyle.right)
                Text(snapshot.right).font(.subheadline)
                TeamCrest(url: snapshot.rightBadge, teamName: snapshot.right, size: 26)
            }
            .padding(10).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        } else {
        VStack(spacing: 18) {
            Text(snapshot.period).font(.subheadline.weight(.semibold)).foregroundStyle(SportsDataStyle.left)
            HStack(alignment: .center, spacing: 14) {
                scoreTeam(snapshot.left, badge: snapshot.leftBadge, tint: SportsDataStyle.left)
                HStack(spacing: 10) {
                    Text(scores[safe: 0] ?? "—").fixedSize(horizontal: true, vertical: false)
                    Text(":").foregroundStyle(Palette.tertiaryText).fixedSize(horizontal: true, vertical: false)
                    Text(scores[safe: 1] ?? "—").fixedSize(horizontal: true, vertical: false)
                }
                .font(.system(size: scoreSize, weight: .bold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.6).lineLimit(1).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
                .accessibilityLabel("比分 \(snapshot.score)")
                scoreTeam(snapshot.right, badge: snapshot.rightBadge, tint: SportsDataStyle.right)
            }
        }
        .padding(.vertical, 22).padding(.horizontal, 14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        }
    }

    private var scoreSize: CGFloat {
        #if os(tvOS)
        return 64
        #else
        return 36
        #endif
    }

    private func scoreTeam(_ name: String, badge: URL?, tint: Color) -> some View {
        VStack(spacing: 8) {
            TeamCrest(url: badge, teamName: name, size: crestSize)
            Text(name).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
            Capsule().fill(tint).frame(width: 24, height: 3)
        }
        .frame(maxWidth: .infinity)
    }
    private var crestSize: CGFloat {
        #if os(tvOS)
        return 72
        #else
        return 42
        #endif
    }

    private func sectionTitle(_ text: String) -> some View {
        HStack(spacing: 9) {
            Rectangle().fill(SportsDataStyle.left).frame(width: 3, height: 16)
            Text(text).font(.headline)
        }
    }

    private func periodScores(_ table: SportsTable) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("分节得分")
            GeometryReader { geometry in
                let width = max(34, (geometry.size.width - 80) / CGFloat(max(1, table.headers.count - 1)))
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        periodRow(table.headers, cellWidth: width, header: true)
                        ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                            periodRow(row, cellWidth: width, header: false)
                        }
                    }
                    .font(.subheadline.monospacedDigit())
                }
                #if os(tvOS)
                .focusable()
                #endif
            }
            .frame(height: SportsDataStyle.rowHeight * CGFloat(table.rows.count + 1))
        }
    }

    private func periodRow(_ row: [String], cellWidth: CGFloat, header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                Text(value).fontWeight(header || index == row.count - 1 ? .semibold : .regular)
                    .foregroundStyle(header ? Palette.secondaryText : Palette.primaryText)
                    .frame(width: index == 0 ? 80 : cellWidth, height: SportsDataStyle.rowHeight,
                           alignment: index == 0 ? .leading : .center)
                    .background(index == row.count - 1 ? SportsDataStyle.left.opacity(0.08) : .clear)
            }
        }
        .background(header ? Color.white.opacity(0.04) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(SportsDataStyle.line).frame(height: 0.5) }
    }

    private func teamComparison(_ table: SportsTable, snapshot: SportsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle("球队对比")
            HStack {
                Label(snapshot.left, systemImage: "circle.fill").foregroundStyle(SportsDataStyle.left)
                Spacer()
                Label(snapshot.right, systemImage: "circle.fill").foregroundStyle(SportsDataStyle.right)
            }.font(.caption.weight(.semibold))
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row[safe: 1] ?? "—").fontWeight(.semibold).foregroundStyle(SportsDataStyle.left)
                        Spacer(minLength: 4)
                        Text(row[safe: 0] ?? "").font(.caption).foregroundStyle(Palette.secondaryText)
                        Spacer(minLength: 4)
                        Text(row[safe: 2] ?? "—").fontWeight(.semibold).foregroundStyle(SportsDataStyle.right)
                    }
                    .font(.subheadline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                    if let metric = SportsStatComparison(row: row) {
                        GeometryReader { geometry in
                            HStack(spacing: 3) {
                                Capsule().fill(SportsDataStyle.left).frame(width: max(0, geometry.size.width - 3) * CGFloat(metric.leftShare))
                                Capsule().fill(SportsDataStyle.right)
                            }
                        }.frame(height: 5)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func playerStatistics(_ snapshot: SportsSnapshot) -> some View {
        let tables = snapshot.playerTables
        if !tables.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    ForEach(Array(tables.enumerated()), id: \.offset) { index, table in
                        Button { selectedTeam = index } label: {
                            Text(table.title.components(separatedBy: " · ").first ?? table.title)
                                .font(.subheadline.weight(.semibold))
                                .padding(.vertical, 10).padding(.horizontal, 18)
                                .background(selectedTeam == index ? SportsDataStyle.left.opacity(0.2) : Palette.surface,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedTeam == index ? SportsDataStyle.left : .clear))
                        }
                        #if os(tvOS)
                        .buttonStyle(.bordered)
                        #else
                        .buttonStyle(.plain)
                        #endif
                        .accessibilityAddTraits(selectedTeam == index ? [.isSelected] : [])
                    }
                    Spacer(minLength: 0)
                }
                let table = tables[min(selectedTeam, tables.count - 1)]
                tableSource(table)
                frozenPlayerTable(table)
                Text("球员姓名固定，左右滚动查看其余统计").font(.caption).foregroundStyle(Palette.secondaryText)
            }
        } else { noStatistics }
    }

    private func frozenPlayerTable(_ table: SportsTable) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                playerCell(table.headers.first ?? "球员", column: 0, header: true, total: false)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    playerCell(row.first ?? "—", column: 0, header: false, total: row.first == "统计")
                        .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.025))
                }
            }
            .background(Palette.backgroundBottom)
            .overlay(alignment: .trailing) { Rectangle().fill(SportsDataStyle.line).frame(width: 1) }
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    playerDataRow(Array(table.headers.dropFirst()), header: true, total: false)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                        playerDataRow(Array(row.dropFirst()), header: false, total: row.first == "统计")
                            .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.025))
                    }
                }
            }
            #if os(tvOS)
            .focusable()
            #endif
        }
        .font(.subheadline.monospacedDigit())
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func playerDataRow(_ row: [String], header: Bool, total: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.offset) { index, value in
                playerCell(value, column: index + 1, header: header, total: total)
            }
        }
    }

    private func playerCell(_ value: String, column: Int, header: Bool, total: Bool) -> some View {
        Text(value).fontWeight(header || total || column == 2 ? .semibold : .regular)
            .foregroundStyle(header ? Palette.secondaryText : (column == 2 ? SportsDataStyle.left : Palette.primaryText))
            .lineLimit(column == 0 ? 2 : 1).minimumScaleFactor(0.75)
            .frame(width: column == 0 ? SportsDataStyle.playerWidth : SportsDataStyle.cellWidth,
                   height: SportsDataStyle.rowHeight, alignment: column == 0 ? .leading : .center)
            .padding(.leading, column == 0 ? 8 : 0)
            .background(header || total ? Color.white.opacity(0.05) : Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(SportsDataStyle.line).frame(height: 0.5) }
    }

    private var noStatistics: some View {
        Text("暂无本场技术统计").font(.subheadline).foregroundStyle(Palette.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 100)
    }
}

struct SportsStatsSheet: View {
    @ObservedObject var model: MatchInsightsModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { SportsStatsContent(model: model).padding(panelPadding) }
                .background(Palette.backgroundBottom)
                .navigationTitle("比赛数据")
                #if !os(tvOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
    }
    private var panelPadding: CGFloat {
        #if os(tvOS)
        return 48
        #else
        return 16
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
