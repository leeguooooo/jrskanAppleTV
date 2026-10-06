import AuthenticationServices
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Sign-in and account status on the TV. Two ways in, side by side: Sign in
/// with Apple using the Apple ID already on the box, or scan a code and
/// approve on the phone — the only way for accounts made with a password,
/// Google or GitHub, since a TV cannot show the account center's web page.
struct AccountView: View {
    @EnvironmentObject private var account: AccountSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var device = DeviceSignInModel()
    @State private var appleNonce = ""

    var body: some View {
        ZStack {
            AppBackground()

            HStack(alignment: .top, spacing: 80) {
                aside
                    .frame(width: 520, alignment: .leading)

                Group {
                    if account.isSignedIn {
                        signedIn
                    } else {
                        signedOut
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .focusSection()
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 60)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onExitCommand { dismiss() }
        .onAppear { if !account.isSignedIn { device.start(session: account) } }
        .onDisappear { device.cancel() }
        .onChange(of: account.isSignedIn) { _, signedIn in
            if signedIn { device.cancel() } else { device.start(session: account) }
        }
        .task { await account.refreshIfStale(maxAge: 60) }
    }

    private var aside: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(height: 120)

            Text("账号")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(Palette.primaryText)

            Text("使用 leeguoo 统一账号。会员权益在 Apple TV、iPhone、iPad 和 Mac 上通用。")
                .font(.callout)
                .foregroundStyle(Palette.secondaryText)

            Text("不登录也能正常看比赛。")
                .font(.callout)
                .foregroundStyle(Palette.tertiaryText)
                .padding(.top, 8)
        }
    }

    // MARK: Signed out

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(alignment: .top, spacing: 40) {
                appleCard
                deviceCard
            }
            .fixedSize(horizontal: false, vertical: true)
            if let error = account.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Palette.live)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appleCard: some View {
        AccountPanel(title: "用 Apple 登录", systemImage: "apple.logo") {
            Text("用这台 Apple TV 上的 Apple ID 登录。第一次登录会自动创建账号。")
                .font(.callout)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            SignInWithAppleButton(.signIn) { request in
                appleNonce = AppleNonce.make()
                request.requestedScopes = [.fullName, .email]
                request.nonce = AppleNonce.sha256(appleNonce)
            } onCompletion: { result in
                let nonce = appleNonce
                Task { await account.signInWithApple(result, nonce: nonce) }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 86)
            .disabled(account.isSigningIn)

            Text("用密码、Google 或 GitHub 注册的账号，请用右边扫码登录。")
                .font(.caption)
                .foregroundStyle(Palette.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 520)
    }

    private var deviceCard: some View {
        AccountPanel(title: "手机扫码登录", systemImage: "qrcode") {
            switch device.status {
            case .waiting(let authorization):
                HStack(alignment: .center, spacing: 36) {
                    QRCodeView(text: (authorization.verificationURIComplete ?? authorization.verificationURI).absoluteString)
                        .frame(width: 260, height: 260)
                        .padding(18)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))

                    VStack(alignment: .leading, spacing: 14) {
                        Text(authorization.userCode)
                            .font(.system(size: 54, weight: .bold, design: .monospaced))
                            .foregroundStyle(Palette.primaryText)
                        Text("用手机相机扫码，或在浏览器打开 \(AccountConfig.deviceURLText) 输入上面的代码。")
                            .font(.callout)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Label("等待手机确认…", systemImage: "hourglass")
                            .font(.callout)
                            .foregroundStyle(Palette.tertiaryText)
                    }
                }
            case .idle, .requesting:
                ProgressView("正在获取登录码…")
                    .frame(maxWidth: .infinity, minHeight: 296)
            case .completed:
                ProgressView("登录成功，正在读取账号…")
                    .frame(maxWidth: .infinity, minHeight: 296)
            case .expired, .denied, .failed:
                VStack(alignment: .leading, spacing: 24) {
                    Text(deviceProblem)
                        .font(.callout)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        device.start(session: account)
                    } label: {
                        Label("重新获取登录码", systemImage: "arrow.clockwise")
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 30)
                            .padding(.vertical, 18)
                    }
                    .buttonStyle(FocusCardButtonStyle())
                }
                .frame(maxWidth: .infinity, minHeight: 296, alignment: .topLeading)
            }
        }
    }

    private var deviceProblem: String {
        switch device.status {
        case .expired: return "登录码已过期。"
        case .denied: return "已在手机上取消这次登录。"
        case .failed(let message): return "获取登录码失败：\(message)"
        default: return ""
        }
    }

    // MARK: Signed in

    private var signedIn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                SettingsGroup(title: "当前账号") {
                    HStack(spacing: 28) {
                        AccountAvatar(name: account.profile?.displayName ?? "", size: 96)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(account.profile?.displayName ?? "正在读取账号…")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Palette.primaryText)
                            if let email = account.profile?.visibleEmail {
                                Text(email)
                                    .font(.callout)
                                    .foregroundStyle(Palette.secondaryText)
                            }
                        }
                        Spacer(minLength: 20)
                    }
                    .padding(30)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                            .fill(Palette.surface.opacity(0.6))
                    )
                }

                SettingsGroup(title: "会员") {
                    SettingsInfoRow(
                        title: account.membership.summary(),
                        value: membershipDetail,
                        systemImage: account.isMember ? "crown.fill" : "crown"
                    )
                    NavigationLink {
                        MembershipPurchaseView()
                    } label: {
                        HStack(spacing: 24) {
                            Image(systemName: "qrcode")
                                .font(.title2)
                                .foregroundStyle(Palette.accent)
                                .frame(width: 48)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(account.membership.purchaseTitle())
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(Palette.primaryText)
                                Text("用手机扫码，微信或支付宝付款。")
                                    .font(.callout)
                                    .foregroundStyle(Palette.secondaryText)
                            }
                            Spacer(minLength: 20)
                            Image(systemName: "chevron.right")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(Palette.tertiaryText)
                        }
                        .padding(.horizontal, 30)
                        .padding(.vertical, 22)
                    }
                    .buttonStyle(FocusCardButtonStyle())
                    SettingsActionRow(
                        title: account.isRefreshing ? "正在刷新…" : "刷新会员状态",
                        subtitle: refreshedText,
                        systemImage: "arrow.clockwise",
                        isDisabled: account.isRefreshing,
                        tint: Palette.accent
                    ) {
                        Task { await account.refreshAccount() }
                    }
                }

                SettingsGroup(title: "登录") {
                    SettingsActionRow(
                        title: "退出登录",
                        subtitle: "只退出这台 Apple TV，不影响其他设备。",
                        systemImage: "rectangle.portrait.and.arrow.right"
                    ) {
                        Task { await account.signOut() }
                    }
                }
            }
            .padding(.bottom, 80)
        }
    }

    private var membershipDetail: String {
        let membership = account.membership
        if account.isMember {
            return membership.isTrial == true
                ? "新账号赠送三个月会员，到期后 \(AccountConfig.priceLabel) 继续使用。"
                : "会员权益已在这台 Apple TV 上生效。"
        }
        return membership.hasLapsed(now: Date())
            ? "会员已到期，\(AccountConfig.priceLabel) 即可继续。"
            : "开通后会员权益在 Apple TV、iPhone、iPad 和 Mac 上通用。"
    }

    private var refreshedText: String {
        guard let checked = account.membership.checkedAt else { return "从账号中心读取最新会员状态。" }
        return "上次更新 \(Self.updatedFormatter.string(from: checked))"
    }

    private static let updatedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

/// Pay on the phone: the TV shows a code for the account center's purchase
/// page and watches the membership until the payment lands.
struct MembershipPurchaseView: View {
    @EnvironmentObject private var account: AccountSession
    @Environment(\.dismiss) private var dismiss
    @State private var startingUntil: Date?
    @State private var paid = false

    var body: some View {
        ZStack {
            AppBackground()

            HStack(alignment: .center, spacing: 90) {
                QRCodeView(text: AccountConfig.membershipURL.absoluteString)
                    .frame(width: 420, height: 420)
                    .padding(28)
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white))

                VStack(alignment: .leading, spacing: 22) {
                    Text(paid ? "开通成功" : "扫码开通会员")
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(Palette.primaryText)
                    Text(AccountConfig.priceLabel)
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                    Text(paid
                         ? account.membership.summary()
                         : "用手机相机扫码，登录同一个账号后用微信或支付宝付款，每付一次开通 3 个月。付款通过爱发电完成。")
                        .font(.title3)
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(paid ? "按 Menu 返回" : "付款后这里会自动刷新…", systemImage: paid ? "checkmark.circle.fill" : "hourglass")
                        .font(.callout)
                        .foregroundStyle(paid ? Palette.accent : Palette.tertiaryText)
                }
                .frame(maxWidth: 760, alignment: .leading)
            }
            .padding(.horizontal, Metrics.gutter)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onExitCommand { dismiss() }
        .task { await watchForPayment() }
    }

    /// Ten minutes of polling covers a slow checkout; any later payment shows
    /// up on the next foreground refresh anyway.
    private func watchForPayment() async {
        startingUntil = account.membership.validUntil
        for _ in 0..<120 {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await account.refreshAccount()
            let membership = account.membership
            let extended = membership.isTrial != true && membership.validUntil.map { new in
                startingUntil.map { new > $0.addingTimeInterval(86400) } ?? true
            } == true
            if extended {
                paid = true
                return
            }
        }
    }
}

/// Entry row for the Settings screen.
struct AccountSettingsRow: View {
    @EnvironmentObject private var account: AccountSession

    var body: some View {
        HStack(spacing: 24) {
            if account.isSignedIn {
                AccountAvatar(name: account.profile?.displayName ?? "", size: 48)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(Palette.accent)
                    .frame(width: 48)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(account.isSignedIn ? (account.profile?.displayName ?? "已登录") : "登录账号")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)
                Text(account.isSignedIn ? account.membership.summary() : "用 Apple 或手机扫码登录，同步会员权益。")
                    .font(.callout)
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer(minLength: 20)
            Image(systemName: "chevron.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Palette.tertiaryText)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
    }
}

private struct AccountPanel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.bold))
                .foregroundStyle(Palette.primaryText)
            content
        }
        .padding(34)
        .frame(maxWidth: .infinity, minHeight: 440, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .fill(Palette.surface.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }
}

struct AccountAvatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Palette.accent.opacity(0.85))
            .frame(width: size, height: size)
            .overlay(
                Text(name.first.map { String($0).uppercased() } ?? "")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}

/// Square, crisp QR code; nearest-neighbour scaling keeps the modules sharp.
struct QRCodeView: View {
    private let image: CGImage?

    init(text: String) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        image = filter.outputImage.flatMap { CIContext().createCGImage($0, from: $0.extent) }
    }

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }
}
