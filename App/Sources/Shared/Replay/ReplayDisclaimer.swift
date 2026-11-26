import SwiftUI

/// What the viewer agrees to before using 回看. Shown once (agreeing is
/// remembered), and always reachable from the 回看 footer.
enum ReplayDisclaimer {
    static let title = "回看使用说明"
    static let points = [
        "回看里的视频来自微博网友公开发布的内容。本应用只做检索和播放，不制作、不上传任何视频；你自己下载的视频只保存在你的设备上。",
        "仅供个人研究学习使用，版权归原权利人所有。",
        "禁止分享、转发、传播、公开放映这些视频（包括下载到本机的视频），也不得用于任何商业用途。",
        "下载的视频只保存在本应用里，不会出现在相册或「文件」中；研究学习完请及时删除。",
        "如果你是权利人并认为内容侵犯了你的权利，请通过 leeguoo.com 联系我们，我们会及时处理。",
    ]
    static let footer = "仅供个人研究学习，禁止分享传播"
    static let agree = "我已阅读并同意"
    static let decline = "不同意"
    static let storageKey = "replayDisclaimerAcceptedV2"

    static var isAccepted: Bool { UserDefaults.standard.bool(forKey: storageKey) }
}

/// The disclaimer as a sheet. \`onAgree\` nil means it is only being re-read.
struct ReplayDisclaimerSheet: View {
    var onAgree: (() -> Void)?
    var onDecline: () -> Void
    @AppStorage(ReplayDisclaimer.storageKey) private var accepted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(ReplayDisclaimer.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(Palette.primaryText)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(ReplayDisclaimer.points.enumerated()), id: \.offset) { index, point in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)").font(.callout.monospacedDigit().weight(.bold)).foregroundStyle(Palette.accent)
                            Text(point).font(.callout).foregroundStyle(Palette.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if let onAgree {
                Button {
                    accepted = true
                    onAgree()
                } label: {
                    Text(ReplayDisclaimer.agree).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(ReplayDisclaimer.decline, role: .cancel, action: onDecline)
                    .frame(maxWidth: .infinity)
            } else {
                Button("知道了", action: onDecline).frame(maxWidth: .infinity)
            }
        }
        .padding(28)
        #if os(tvOS)
        .frame(maxWidth: 1100)
        #else
        .presentationDetents([.medium, .large])
        #endif
        .interactiveDismissDisabled(onAgree != nil)
        .background(Palette.backgroundTop.ignoresSafeArea())
    }
}
