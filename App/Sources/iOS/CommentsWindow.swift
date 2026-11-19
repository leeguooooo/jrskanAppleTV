#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Mac only: the live comments of one match in a small window of their own.
/// It polls on its own, so it keeps going with the player closed, covered or
/// minimised, and it can float above other apps (置顶) and fade (透明度), so
/// the match can be followed in a corner of a work screen without a picture.
/// Comments exist only for NBA and CBA, like the danmaku.
enum CommentsWindow {
    static let sceneID = "comments"

    /// Channels already resolved by the match screen, which identify the
    /// match to the comment providers better than the homepage entries.
    @MainActor static var channels: [String: [MatchSource]] = [:]
}

/// How many comments windows are open: while one is, the danmaku over the
/// video is redundant and only draws the eye, so the player hides it.
@MainActor
final class CommentsWindowPresence: ObservableObject {
    static let shared = CommentsWindowPresence()
    @Published private(set) var openCount = 0
    var isOpen: Bool { openCount > 0 }
    func opened() { openCount += 1 }
    func closed() { openCount = max(0, openCount - 1) }
}

/// Provider emoticon codes such as [笑哭了] shown as the emoji they stand for;
/// unknown codes stay as written.
enum CommentEmoji {
    static let table: [String: String] = [
        "笑哭了": "😂", "笑哭": "😂", "破涕为笑": "😂", "笑嘻嘻": "😄", "哈哈": "😆", "大笑": "😆", "笑": "😄",
        "呲牙": "😁", "微笑": "🙂", "憨笑": "😊", "害羞": "😊", "偷笑": "🤭", "坏笑": "😏", "捂脸": "🤦",
        "尴尬": "😅", "流汗": "😓", "汗": "😓", "擦汗": "😓", "大哭": "😭", "流泪": "😭", "哭": "😭",
        "可怜": "🥺", "委屈": "🥺", "生气": "😠", "发怒": "😡", "怒": "😡", "抓狂": "😫", "惊讶": "😮",
        "惊恐": "😱", "疑问": "❓", "晕": "😵", "酷": "😎", "得意": "😎", "鄙视": "😒", "白眼": "🙄",
        "无语": "😑", "睡": "😴", "困": "😪", "吐": "🤮", "色": "😍", "亲亲": "😘", "思考": "🤔",
        "吃瓜": "🍉", "狗头": "🐶", "二哈": "🐶", "赞": "👍", "点赞": "👍", "强": "👍", "棒": "👍",
        "弱": "👎", "鼓掌": "👏", "抱拳": "🙏", "握手": "🤝", "OK": "👌", "胜利": "✌️", "加油": "💪",
        "奋斗": "💪", "再见": "👋", "爱心": "❤️", "心": "❤️", "心碎": "💔", "玫瑰": "🌹", "啤酒": "🍺",
        "篮球": "🏀", "足球": "⚽", "火": "🔥", "666": "👍", "牛": "🐮", "炸弹": "💣", "庆祝": "🎉"
    ]

    static func render(_ text: String) -> String {
        guard text.contains("[") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            result += rest[..<open]
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: "]"), after.distance(from: after.startIndex, to: close) <= 8 else {
                result += "["
                rest = after
                continue
            }
            let name = String(after[..<close])
            result += table[name] ?? "[\(name)]"
            rest = after[after.index(after: close)...]
        }
        return result + rest
    }
}

/// Opens (or brings forward) the comments window for a match.
struct CommentsWindowButton: View {
    let match: LiveMatch
    let channels: [MatchSource]
    var chip = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            CommentsWindow.channels[match.id] = channels
            openWindow(id: CommentsWindow.sceneID, value: match.id)
        } label: {
            if chip {
                Label("评论小窗", systemImage: "text.bubble")
                    .font(.footnote.weight(.semibold))
                    .padding(8)
                    .playerChip()
            } else {
                Label("只看评论（小窗，可置顶）", systemImage: "text.bubble")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityLabel("打开评论小窗")
    }
}

/// Comments for the window: the providers return what was posted in the last
/// two minutes; this keeps a longer history so the window reads like a chat.
@MainActor
final class CommentFeedModel: ObservableObject {
    @Published private(set) var comments: [SportsComment] = []
    @Published private(set) var status = "正在连接评论…"
    private let client = MultiSportsClient(tencent: TencentSportsClient())
    private var seen: [String] = []

    static func hasComments(_ match: LiveMatch) -> Bool {
        ["NBA", "CBA"].contains(match.league.uppercased())
    }

    /// Polls every 10 seconds until the task is cancelled (window closed or
    /// sent to the background). Never overlaps requests.
    func run(match: LiveMatch, channels: [MatchSource]) async {
        guard Self.hasComments(match) else { status = "只有 NBA、CBA 比赛有评论"; return }
        while !Task.isCancelled {
            do {
                let batch = try await client.comments(match: match, channels: channels, excluding: Set(seen))
                try Task.checkCancellation()
                for comment in batch where !seen.contains(comment.id) {
                    seen.append(comment.id)
                    // The same line posted again and again (湖人总冠军…) shows once.
                    guard !comments.suffix(8).contains(where: { $0.text == comment.text }) else { continue }
                    comments.append(SportsComment(id: comment.id, text: CommentEmoji.render(comment.text),
                                                  postedAt: comment.postedAt))
                }
                comments = Array(comments.suffix(300))
                seen = Array(seen.suffix(1000))
                status = comments.isEmpty ? "还没有新评论，10 秒后再看" : ""
            } catch {
                if Task.isCancelled { return }
                // An empty Tencent answer falls through to Migu, which throws when
                // it has no such match: usually just a quiet comment section.
                status = comments.isEmpty ? "暂时没有评论，10 秒后再看" : ""
            }
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
        }
    }
}

struct CommentsWindowScreen: View {
    let matchID: String?
    @EnvironmentObject private var listModel: MatchListModel
    @ObservedObject private var session = PlayerSession.shared
    @StateObject private var feed = CommentFeedModel()
    /// Score, team and player statistics for /score and /players.
    @StateObject private var insights = MatchInsightsModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var window = MacWindowHandle()
    @State private var pinned = false
    @State private var opacity = 1.0
    /// Channels with Tencent's event ID, needed to find the comments.
    @State private var channels: [MatchSource]?
    /// Dressed as a terminal running an AI coding agent, so a glance at the
    /// screen reads as work. On by default; the plain look is one click away.
    @AppStorage("commentsTerminalSkin") private var terminal = true

    private var match: LiveMatch? {
        guard let matchID else { return nil }
        if let current = listModel.matches.first(where: { $0.id == matchID }) { return current }
        if let playing = session.model?.match, playing.id == matchID { return playing }
        return nil
    }

    var body: some View {
        Group {
            if terminal {
                TerminalCommentsView(match: match, feed: feed, insights: insights) { controls }
            } else {
                VStack(spacing: 0) {
                    header
                    Divider().overlay(Palette.hairline)
                    content
                }
                .background(Palette.backgroundBottom.ignoresSafeArea())
                .foregroundStyle(Palette.primaryText)
            }
        }
        .background(WindowProbe { scene in
            // Small and out of the way; the title (Window menu, Mission
            // Control) says only zsh or 评论.
            scene.sizeRestrictions?.minimumSize = CGSize(width: 260, height: 180)
            scene.sizeRestrictions?.maximumSize = CGSize(width: 640, height: 1400)
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbar = nil
            window.attach(scene, title: terminal ? "zsh" : "评论")
        })
        .onChange(of: terminal) { _, on in window.setTitle(on ? "zsh" : "评论") }
        #if DEBUG
        // `-comments-pin` floats the window at once, to check 置顶 without a click.
        .task {
            guard CommandLine.arguments.contains("-comments-pin") else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            pinned = window.setFloating(true)
            print("comments-window pinned=\(pinned)")
        }
        #endif
        // Stops when the window closes or the app is hidden; a window that is
        // merely behind another app keeps polling, which is the point of it.
        // The comment providers find the match through the event ID in the
        // resolved channel pages; the homepage entries usually lack it. A window
        // restored at launch, or opened before the match screen finished
        // loading, resolves the channels itself.
        .task(id: "channels-\(matchID ?? "")-\(match != nil)") {
            guard let match, channels == nil else { return }
            if let known = CommentsWindow.channels[match.id], TencentSportsClient.candidateMID(match: match, channels: known) != nil {
                channels = known
                return
            }
            if let playing = session.model, playing.match.id == match.id, playing.channels != nil {
                channels = playing.resolvedChannels
                return
            }
            let loader = MatchPlaybackModel(match: match, preferences: listModel.preferences)
            await loader.loadChannels()
            guard !Task.isCancelled else { return }
            channels = loader.resolvedChannels
            CommentsWindow.channels[match.id] = loader.resolvedChannels
        }
        .task(id: "\(matchID ?? "")-\(match != nil)-\(channels?.count ?? -1)-\(scenePhase == .background)") {
            guard scenePhase != .background, let match, let channels else { return }
            await feed.run(match: match, channels: channels)
        }
        .task(id: "stats-\(matchID ?? "")-\(match != nil)-\(channels?.count ?? -1)-\(scenePhase == .background)") {
            guard scenePhase != .background, let match, let channels, CommentFeedModel.hasComments(match) else { return }
            await insights.watch(match: match, channels: channels)
        }
        .onAppear { CommentsWindowPresence.shared.opened() }
        .onDisappear { CommentsWindowPresence.shared.closed() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let match {
                scoreLine(match)
            } else {
                Text("评论").font(.subheadline.weight(.semibold))
            }
            Spacer(minLength: 4)
            controls
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: terminal ? 2 : 8) {
            iconButton("terminal", label: terminal ? "普通样式" : "终端样式", active: false) { terminal.toggle() }
            if session.model?.match.id == matchID, session.model?.playback != nil {
                iconButton(session.isCovered ? "eye.slash.fill" : "eye",
                           label: session.isCovered ? "显示视频画面" : "遮住视频画面（声音继续）",
                           active: session.isCovered) { session.isCovered.toggle() }
            }
            iconButton("circle.lefthalf.filled", label: "透明度 \(Int(opacity * 100))%", active: opacity < 1) {
                opacity = opacity > 0.9 ? 0.7 : opacity > 0.6 ? 0.45 : 1
                window.setAlpha(opacity)
            }
            iconButton(pinned ? "pin.fill" : "pin", label: pinned ? "取消置顶" : "置顶", active: pinned) {
                pinned = window.setFloating(!pinned)
            }
        }
    }

    private func scoreLine(_ match: LiveMatch) -> some View {
        let status = MatchSchedule.status(for: match, now: Date())
        var score: String?
        if match.scoreText != nil, let home = match.providerState?.homeScore, let away = match.providerState?.awayScore {
            score = "\(home) : \(away)"
        }
        return HStack(spacing: 6) {
            Text(match.homeTeam).lineLimit(1)
            Text(score ?? "VS").font(BrandFont.numeric(14, bold: true, relativeTo: .subheadline))
                .foregroundStyle(score == nil ? Palette.tertiaryText : Palette.primaryText)
            Text(match.awayTeam).lineLimit(1)
            if case .live(let label) = status {
                Text(label).font(.caption2).foregroundStyle(Palette.secondaryText).lineLimit(1)
            }
        }
        .font(.footnote.weight(.semibold))
        .minimumScaleFactor(0.8)
    }

    private func iconButton(_ symbol: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if terminal {
                // Faint glyphs, no chips: the terminal look has no buttons.
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .regular))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(active ? TerminalStyle.text : TerminalStyle.faint)
            } else {
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(active ? Palette.accent : Palette.secondaryText)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    @ViewBuilder
    private var content: some View {
        if match == nil {
            placeholder(matchID == nil ? "在比赛页点「只看评论」打开" : "这场比赛已不在赛程里")
        } else if feed.comments.isEmpty {
            placeholder(feed.status)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(feed.comments) { comment in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(comment.postedAt, format: .dateTime.hour().minute())
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Palette.tertiaryText)
                                Text(comment.text)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(comment.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: feed.comments.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.secondaryText)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum TerminalStyle {
    static let background = Color(hex: 0x111111)
    static let text = Color(hex: 0xD6D6D6)
    static let dim = Color(hex: 0x8A8A8A)
    static let faint = Color(hex: 0x555555)
    static let bullet = Color(hex: 0x7FA37F)
    static let font = Font.system(size: 12, design: .monospaced)
}

/// Short English terms in place of the Chinese sports words, so the score
/// and box score read like a program's printout: NBA teams by tricode,
/// statistics by their usual abbreviations. Player names and CBA teams stay.
enum Term {
    static let teams: [String: String] = [
        "老鹰": "ATL", "凯尔特人": "BOS", "篮网": "BKN", "黄蜂": "CHA", "公牛": "CHI", "骑士": "CLE",
        "独行侠": "DAL", "小牛": "DAL", "掘金": "DEN", "活塞": "DET", "勇士": "GSW", "火箭": "HOU",
        "步行者": "IND", "快船": "LAC", "湖人": "LAL", "灰熊": "MEM", "热火": "MIA", "雄鹿": "MIL",
        "森林狼": "MIN", "鹈鹕": "NOP", "尼克斯": "NYK", "雷霆": "OKC", "魔术": "ORL", "76人": "PHI",
        "太阳": "PHX", "开拓者": "POR", "国王": "SAC", "马刺": "SAS", "猛龙": "TOR", "爵士": "UTA", "奇才": "WAS"
    ]
    static let words: [String: String] = [
        "球队": "team", "项目": "stat", "球员": "player", "号码 / 球员": "player", "总分": "tot", "统计": "total",
        "时间": "min", "得分": "pts", "篮板": "reb", "前场篮板": "oreb", "后场篮板": "dreb", "助攻": "ast",
        "抢断": "stl", "盖帽": "blk", "失误": "tov", "犯规": "pf", "投篮": "fg", "三分": "3p", "罚球": "ft",
        "投篮命中率": "fg%", "三分命中率": "3p%", "罚球命中率": "ft%", "真实命中率": "ts%", "加时": "ot",
        "快攻得分": "fbpts", "内线得分": "paint", "最大领先": "max lead", "替补得分": "bench"
    ]

    static func of(_ text: String) -> String {
        if let team = teams[text] { return team }
        if let word = words[text] { return word }
        // 第1节 / 第一节 → q1
        let digits = ["一": "1", "二": "2", "三": "3", "四": "4"]
        if text.hasPrefix("第"), text.hasSuffix("节") {
            let middle = String(text.dropFirst().dropLast())
            return "q" + (digits[middle] ?? middle)
        }
        return text
    }

    /// Headers always; the first column too when it holds teams or stat names.
    static func table(_ table: SportsTable, firstColumn: Bool) -> SportsTable {
        SportsTable(title: table.title, headers: table.headers.map(of),
                    rows: table.rows.map { row in
                        firstColumn ? row.enumerated().map { $0.offset == 0 ? of($0.element) : $0.element } : row
                    },
                    sourceName: table.sourceName)
    }
}

/// The comments as the scrollback of an AI coding agent in a terminal: each
/// comment a ⏺ line, the score folded into the agent's status line, a prompt
/// at the bottom. The prompt's commands switch between /comments, /score
/// (分节比分 and 球队技术统计) and /players (both teams' box scores), each
/// drawn as a tool call and its output. No logos or colours.
private struct TerminalCommentsView<Controls: View>: View {
    enum Pane: String, CaseIterable { case comments, score, players }

    let match: LiveMatch?
    @ObservedObject var feed: CommentFeedModel
    @ObservedObject var insights: MatchInsightsModel
    @ViewBuilder let controls: () -> Controls
    @AppStorage("commentsTerminalPane") private var pane = Pane.comments
    @State private var tick = 0
    @State private var started = Date()
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("~/work/service").foregroundStyle(TerminalStyle.bullet)
                Text(" (main) ").foregroundStyle(TerminalStyle.dim)
                Text("% agent").foregroundStyle(TerminalStyle.text)
                Spacer(minLength: 4)
                controls()
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)
            // Like a real terminal, the newest output sits right above the
            // prompt; short output leaves the empty space at the top.
            GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        Spacer(minLength: 0)
                        switch pane {
                        case .comments: commentLines
                        case .score: scoreOutput
                        case .players: playersOutput
                        }
                        statusLine.id("status")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .bottomLeading)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: feed.comments.last?.id) { _, _ in
                    guard pane == .comments else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("status", anchor: .bottom) }
                }
                .onChange(of: pane) { _, _ in proxy.scrollTo("status", anchor: .bottom) }
            }
            }
            prompt
        }
        .font(TerminalStyle.font)
        .background(TerminalStyle.background.ignoresSafeArea())
        .onReceive(clock) { _ in tick += 1 }
    }

    // MARK: Panes

    @ViewBuilder
    private var commentLines: some View {
        ForEach(feed.comments) { comment in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("⏺").foregroundStyle(TerminalStyle.bullet)
                Text(comment.text).foregroundStyle(TerminalStyle.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(comment.id)
        }
        if feed.comments.isEmpty {
            output(match == nil ? "no session" : "waiting for output…")
        }
    }

    @ViewBuilder
    private var scoreOutput: some View {
        toolCall("Bash", "./scripts/status --live")
        if let snapshot = insights.snapshot {
            output("\(Term.of(snapshot.left))  \(snapshot.score)  \(Term.of(snapshot.right))   \(snapshot.period)")
            if let periods = snapshot.periodTable {
                table(Term.table(periods, firstColumn: true)).padding(.leading, 26).padding(.top, 4)
            }
            if let comparison = snapshot.comparisonTable {
                toolCall("Read", "team_stats.json").padding(.top, 8)
                table(Term.table(comparison, firstColumn: true)).padding(.leading, 26).padding(.top, 2)
            }
            // The scoreboard and the tables can come from different providers;
            // the tables often trail by a poll or two.
            Text("     updated \(snapshot.updatedAt.formatted(date: .omitted, time: .standard))")
                .foregroundStyle(TerminalStyle.faint)
        } else {
            output(insights.status.isEmpty ? "no data yet" : insights.status)
        }
    }

    @ViewBuilder
    private var playersOutput: some View {
        if let snapshot = insights.snapshot, !snapshot.playerTables.isEmpty {
            ForEach(Array(snapshot.playerTables.enumerated()), id: \.offset) { index, original in
                let team = original.title.components(separatedBy: " · ").first ?? original.title
                toolCall("Read", "players/\(index == 0 ? "home" : "away").json")
                    .padding(.top, index == 0 ? 0 : 8)
                output(Term.of(team))
                table(Term.table(Self.compact(original), firstColumn: false), firstColumnWidth: 120).padding(.leading, 26).padding(.top, 2)
            }
        } else {
            toolCall("Read", "players/*.json")
            output(insights.status.isEmpty ? "no data yet" : insights.status)
        }
    }

    /// The box score cut to what fits a small window: player, minutes, points,
    /// rebounds, assists, shooting when the provider has them.
    static func compact(_ table: SportsTable) -> SportsTable {
        let wanted = ["时间", "得分", "篮板", "助攻", "投篮", "三分", "+/-"]
        var columns = [0]
        for name in wanted {
            if let index = table.headers.firstIndex(where: { $0 == name }), !columns.contains(index) { columns.append(index) }
        }
        if columns.count == 1 { columns = Array(0..<min(table.headers.count, 6)) }
        func pick(_ row: [String]) -> [String] { columns.map { $0 < row.count ? row[$0] : "" } }
        return SportsTable(title: table.title, headers: pick(table.headers), rows: table.rows.map(pick),
                           sourceName: table.sourceName)
    }

    // MARK: Pieces

    private func toolCall(_ tool: String, _ argument: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("⏺").foregroundStyle(TerminalStyle.bullet)
            (Text(tool).bold().foregroundColor(TerminalStyle.text) + Text("(\(argument))").foregroundColor(TerminalStyle.dim))
        }
    }

    private func output(_ text: String) -> some View {
        Text("  ⎿  " + text).foregroundStyle(TerminalStyle.dim).textSelection(.enabled)
    }

    private func table(_ table: SportsTable, firstColumnWidth: CGFloat = 96) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            GridRow {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { index, header in
                    Text(header).foregroundStyle(TerminalStyle.faint)
                        .frame(width: index == 0 ? firstColumnWidth : nil, alignment: .leading)
                }
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                        Text(cell).foregroundStyle(index == 0 ? TerminalStyle.dim : TerminalStyle.text)
                            .lineLimit(1)
                            .frame(width: index == 0 ? firstColumnWidth : nil, alignment: .leading)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private var prompt: some View {
        HStack(spacing: 10) {
            Text("❯").foregroundStyle(TerminalStyle.text)
            ForEach(Pane.allCases, id: \.self) { item in
                Button("/\(item.rawValue)") { pane = item }
                    .buttonStyle(.plain)
                    .foregroundStyle(item == pane ? TerminalStyle.text : TerminalStyle.faint)
            }
            Rectangle().fill(TerminalStyle.text.opacity(tick.isMultiple(of: 2) ? 0.8 : 0)).frame(width: 7, height: 14)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Rectangle().fill(TerminalStyle.faint.opacity(0.6)).frame(height: 1) }
    }

    /// Spinner glyph and elapsed seconds move like a real agent's status line.
    private var statusLine: some View {
        let glyphs = ["✻", "✶", "✳", "✢", "·", "✢", "✳", "✶"]
        return HStack(spacing: 0) {
            Text(glyphs[tick % glyphs.count] + " ").foregroundStyle(TerminalStyle.bullet)
            Text("Working… ").foregroundStyle(TerminalStyle.dim)
            Text("(\(statusDetail))").foregroundStyle(TerminalStyle.faint)
        }
        .padding(.top, 4)
    }

    /// e.g. "73s · q3 08:12 · 102↑ 98↓ tokens · esc to interrupt".
    private var statusDetail: String {
        var parts = ["\(Int(Date().timeIntervalSince(started)))s"]
        if let snapshot = insights.snapshot {
            if !snapshot.period.isEmpty { parts.append(Self.period(snapshot.period)) }
            let scores = snapshot.score.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            if scores.count == 2 { parts.append("\(scores[0])↑ \(scores[1])↓ tokens") }
        } else if let match {
            if case .live(let label) = MatchSchedule.status(for: match, now: Date()) { parts.append(Self.period(label)) }
            if match.scoreText != nil, let home = match.providerState?.homeScore, let away = match.providerState?.awayScore {
                parts.append("\(home)↑ \(away)↓ tokens")
            }
        }
        parts.append("esc to interrupt")
        return parts.joined(separator: " · ")
    }

    /// 第三节 08:12 → q3 08:12, 第一节结束 → q1 end; anything else Chinese → live.
    static func period(_ label: String) -> String {
        let map = ["第一节": "q1", "第二节": "q2", "第三节": "q3", "第四节": "q4", "上半场": "h1", "下半场": "h2",
                   "中场": "ht", "加时": "ot", "节间": "break", "已结束": "done", "完赛": "done"]
        for (chinese, short) in map where label.contains(chinese) {
            let rest = label.replacingOccurrences(of: chinese, with: "")
                .replacingOccurrences(of: "结束", with: "end").trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? short : "\(short) \(rest)"
        }
        return label.unicodeScalars.contains { $0.value > 0x2E7F } ? "live" : label
    }
}

/// Reports the window scene a view lands in.
struct WindowProbe: UIViewRepresentable {
    let found: (UIWindowScene) -> Void
    func makeUIView(context: Context) -> ProbeView { ProbeView(found: found) }
    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        let found: (UIWindowScene) -> Void
        init(found: @escaping (UIWindowScene) -> Void) {
            self.found = found
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { found(scene) }
        }
    }
}

/// The comments window's AppKit window, for what Catalyst has no API for:
/// floating above other apps and transparency. Reached only through public
/// AppKit names (`NSApplication.sharedApplication.windows`, `title`, `level`,
/// `alphaValue`, `collectionBehavior`); if it cannot be found the buttons
/// simply do nothing.
@MainActor
final class MacWindowHandle {
    private weak var scene: UIWindowScene?
    private weak var nsWindow: NSObject?
    func setTitle(_ title: String) { scene?.title = title }

    /// Whether the window is floating right now.
    private(set) var isFloating = false

    /// Finds the scene's NSWindow; `title` is what the scene is called afterwards.
    func attach(_ scene: UIWindowScene, title: String) {
        guard self.scene !== scene else { return }
        self.scene = scene
        // Several windows may be open: tag this one with a unique title just
        // long enough to pick out its NSWindow.
        let token = "window-" + UUID().uuidString
        scene.title = token
        Task { @MainActor in
            for _ in 0..<20 {
                if let window = Self.appKitWindows().first(where: { ($0.value(forKey: "title") as? String) == token }) {
                    nsWindow = window
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            scene.title = title
        }
    }

    /// Returns whether the window now floats.
    func setFloating(_ floating: Bool) -> Bool {
        guard let nsWindow else { return false }
        // NSFloatingWindowLevel = 3, NSNormalWindowLevel = 0.
        nsWindow.setValue(floating ? 3 : 0, forKey: "level")
        // canJoinAllSpaces (1 << 0) | fullScreenAuxiliary (1 << 8): stay
        // visible on every desktop and over a full-screen app.
        nsWindow.setValue(floating ? (1 << 0 | 1 << 8) : 0, forKey: "collectionBehavior")
        isFloating = floating
        return floating
    }

    func setAlpha(_ alpha: Double) {
        nsWindow?.setValue(alpha, forKey: "alphaValue")
    }

    private static func appKitWindows() -> [NSObject] {
        guard let type = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = type.value(forKey: "sharedApplication") as? NSObject else { return [] }
        return app.value(forKey: "windows") as? [NSObject] ?? []
    }
}
#endif
