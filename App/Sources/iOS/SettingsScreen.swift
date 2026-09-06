import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var model: MatchListModel
    @EnvironmentObject private var preferences: Preferences
    @State private var clearedHistory = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $preferences.autoNextChannel) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("线路失效时自动换下一条")
                        Text("解析失败或 20 秒没有画面时，直接尝试下一条线路。")
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                Toggle(isOn: $preferences.autoRefresh) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自动刷新赛程")
                        Text("列表停留时每 5 分钟更新一次，回到前台也会检查。")
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
            } header: {
                Text("播放与刷新")
            }

            Section {
                if preferences.favoriteTeams.isEmpty {
                    Text("还没有关注球队，在比赛详情里点「关注」添加。")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryText)
                } else {
                    ForEach(preferences.favoriteTeams.sorted(), id: \.self) { team in
                        Label(team, systemImage: "star.fill")
                    }
                    .onDelete { offsets in
                        let sorted = preferences.favoriteTeams.sorted()
                        for offset in offsets { preferences.toggleFavorite(sorted[offset]) }
                    }
                }
                Button(role: .destructive) {
                    preferences.clearHistory()
                    model.filter = .all
                    clearedHistory = true
                } label: {
                    Label(clearedHistory ? "已清除" : "清除关注与观看记录", systemImage: "trash")
                }
                .disabled(!preferences.hasHistory)
            } header: {
                Text("关注与记录")
            } footer: {
                Text("左滑可移除单个关注球队。")
            }

            Section {
                infoRow("内容来源", "应用只读取公开网页上的赛程与线路，不托管、不重新分发任何视频，也不绕过登录、DRM、付费墙或地域限制。线路由第三方维护，可能随时失效。")
                infoRow("隐私", "不需要账号，不收集任何个人信息，不接入分析或广告 SDK。关注与观看记录仅存于本机。")
            } header: {
                Text("关于")
            } footer: {
                Text("JRKAN · 版本 \(Self.versionText)")
                    .padding(.top, 8)
            }
        }
        .scrollContentBackground(.hidden)
        .background(TouchBackground())
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(value).font(.caption).foregroundStyle(Palette.secondaryText)
        }
        .padding(.vertical, 2)
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }
}
