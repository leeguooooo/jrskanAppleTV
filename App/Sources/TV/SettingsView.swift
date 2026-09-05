import SwiftUI

/// Preferences plus the "about" text an App Store build has to carry: what
/// the app does and does not do with the viewer's data, and where the
/// content comes from.
struct SettingsView: View {
    @EnvironmentObject private var model: MatchListModel
    @ObservedObject private var preferences: Preferences
    @Environment(\.dismiss) private var dismiss
    @State private var clearedHistory = false

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    var body: some View {
        ZStack {
            AppBackground()

            HStack(alignment: .top, spacing: 80) {
                aside
                    .frame(width: 520, alignment: .leading)

                ScrollView {
                    VStack(alignment: .leading, spacing: 44) {
                        playbackSection
                        historySection
                        aboutSection
                    }
                    .padding(.bottom, 80)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .focusSection()
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 60)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onExitCommand { dismiss() }
    }

    private var aside: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(height: 120)

            Text("设置")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(Palette.primaryText)

            Text("JRKAN · 版本 \(Self.versionText)")
                .font(.callout)
                .foregroundStyle(Palette.tertiaryText)

            Text("所有设置与记录只保存在这台 Apple TV 上。")
                .font(.callout)
                .foregroundStyle(Palette.secondaryText)
                .padding(.top, 8)
        }
    }

    // MARK: Sections

    private var playbackSection: some View {
        SettingsGroup(title: "播放与刷新") {
            SettingsToggleRow(
                title: "线路失效时自动换下一条",
                subtitle: "解析失败或 20 秒没有画面时，直接尝试下一条线路。",
                systemImage: "arrow.triangle.2.circlepath",
                isOn: $preferences.autoNextChannel
            )
            SettingsToggleRow(
                title: "自动刷新赛程",
                subtitle: "列表停留时每 5 分钟更新一次，回到前台也会检查。",
                systemImage: "clock.arrow.circlepath",
                isOn: $preferences.autoRefresh
            )
        }
    }

    private var historySection: some View {
        SettingsGroup(title: "关注与记录") {
            SettingsInfoRow(
                title: "关注的球队",
                value: preferences.favoriteTeams.isEmpty
                    ? "还没有关注球队，在比赛详情里按「关注」添加。"
                    : preferences.favoriteTeams.sorted().joined(separator: " · "),
                systemImage: "star.fill"
            )
            SettingsActionRow(
                title: clearedHistory ? "已清除" : "清除关注与观看记录",
                subtitle: "移除所有关注球队和「上次线路」记忆。",
                systemImage: "trash",
                isDisabled: !preferences.hasHistory
            ) {
                preferences.clearHistory()
                model.filter = .all
                clearedHistory = true
            }
        }
    }

    private var aboutSection: some View {
        SettingsGroup(title: "关于") {
            SettingsInfoRow(
                title: "内容来源",
                value: "应用只读取公开网页上的赛程与线路，不托管、不重新分发任何视频，也不绕过登录、DRM、付费墙或地域限制。线路由第三方维护，可能随时失效。",
                systemImage: "globe"
            )
            SettingsInfoRow(
                title: "隐私",
                value: "不需要账号，不收集任何个人信息，不接入分析或广告 SDK。关注与观看记录仅存于本机。",
                systemImage: "hand.raised.fill"
            )
            SettingsInfoRow(
                title: "遥控器",
                value: "上下选择比赛，左右切换分类；播放中按住触控板打开线路菜单，按 Menu 返回。",
                systemImage: "tv.and.mediabox"
            )
        }
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }
}

// MARK: - Rows

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Palette.accent)
                .padding(.leading, 6)
            content
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 24) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Palette.accent)
                    .frame(width: 48)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.primaryText)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(Palette.secondaryText)
                }

                Spacer(minLength: 20)

                SwitchGlyph(isOn: isOn)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 22)
        }
        .buttonStyle(FocusCardButtonStyle())
    }
}

/// A drawn toggle instead of `Toggle`: the system control on tvOS carries
/// its own focus plate and label layout, which fights the card style every
/// other row uses.
private struct SwitchGlyph: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Palette.accent : Color.white.opacity(0.18))
                .frame(width: 84, height: 46)
            Circle()
                .fill(.white)
                .frame(width: 36, height: 36)
                .padding(5)
        }
        .animation(.easeOut(duration: 0.18), value: isOn)
    }
}

private struct SettingsActionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(isDisabled ? Palette.tertiaryText : Palette.live)
                    .frame(width: 48)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(isDisabled ? Palette.secondaryText : Palette.primaryText)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(Palette.secondaryText)
                }
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 22)
        }
        .buttonStyle(FocusCardButtonStyle())
        .disabled(isDisabled)
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Palette.accent)
                .frame(width: 48)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)
                Text(value)
                    .font(.callout)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .fill(Palette.surface.opacity(0.6))
        )
    }
}
