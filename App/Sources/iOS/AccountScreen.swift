import AuthenticationServices
import SwiftUI

/// Sign-in and account status on iPhone, iPad and Mac. Apple is the native
/// button; every other method (password, Google, GitHub) goes through the
/// account center's own sign-in page in a web authentication sheet, which
/// also reuses an account center session Safari already has.
struct AccountScreen: View {
    @EnvironmentObject private var account: AccountSession
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.openURL) private var openURL
    @State private var appleNonce = ""

    var body: some View {
        Form {
            if account.isSignedIn {
                signedIn
            } else {
                signedOut
            }
        }
        .scrollContentBackground(.hidden)
        .background(TouchBackground())
        .navigationTitle("账号")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await account.refreshIfStale(maxAge: 60) }
        .refreshable { await account.refreshAccount() }
    }

    // MARK: Signed out

    @ViewBuilder private var signedOut: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("登录 leeguoo 账号").font(.headline)
                Text("会员权益在 iPhone、iPad、Mac 和 Apple TV 上通用。不登录也能正常看比赛。")
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
            }
            .padding(.vertical, 4)
        }

        Section {
            SignInWithAppleButton(.signIn) { request in
                appleNonce = AppleNonce.make()
                request.requestedScopes = [.fullName, .email]
                request.nonce = AppleNonce.sha256(appleNonce)
            } onCompletion: { result in
                let nonce = appleNonce
                Task { await account.signInWithApple(result, nonce: nonce) }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 48)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }

        Section {
            Button {
                Task { await signInOnWeb() }
            } label: {
                Label("使用邮箱、Google 或 GitHub 登录", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .disabled(account.isSigningIn)
        } footer: {
            if account.isSigningIn {
                Text("正在登录…")
            } else if let error = account.lastError {
                Text(error).foregroundStyle(Palette.live)
            }
        }
    }

    private func signInOnWeb() async {
        let pkce = PKCE()
        let state = PKCE.randomURLSafe(bytes: 16)
        let callback: URL
        do {
            callback = try await webAuthenticationSession.authenticate(
                using: account.api.authorizeURL(pkce: pkce, state: state),
                callbackURLScheme: AccountConfig.callbackScheme
            )
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                account.lastError = "登录没有完成：\(error.localizedDescription)"
            }
            return
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("state") == state else {
            account.lastError = "登录回调校验失败，请重试。"
            return
        }
        guard let code = value("code") else {
            if let error = value("error") { account.lastError = value("error_description") ?? error }
            return
        }
        await account.run { try await account.api.exchangeCode(code, pkce: pkce) }
    }

    // MARK: Signed in

    @ViewBuilder private var signedIn: some View {
        Section {
            HStack(spacing: 14) {
                AccountInitialAvatar(name: account.profile?.displayName ?? "", size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.profile?.displayName ?? "正在读取账号…").font(.headline)
                    if let email = account.profile?.visibleEmail {
                        Text(email).font(.subheadline).foregroundStyle(Palette.secondaryText)
                    }
                }
            }
            .padding(.vertical, 4)
        }

        Section {
            Label(account.membership.summary(), systemImage: account.isMember ? "crown.fill" : "crown")
                .foregroundStyle(account.isMember ? Palette.primaryText : Palette.secondaryText)
            Button {
                Task { await account.refreshAccount() }
            } label: {
                Label(account.isRefreshing ? "正在刷新…" : "刷新会员状态", systemImage: "arrow.clockwise")
            }
            .disabled(account.isRefreshing)
        } header: {
            Text("会员")
        } footer: {
            Text("开通与续费在账号中心进行，完成后回到这里刷新。")
        }

        Section {
            Button {
                openURL(AccountConfig.manageURL)
            } label: {
                Label("管理账号与登录方式", systemImage: "arrow.up.right.square")
            }
            Button(role: .destructive) {
                Task { await account.signOut() }
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } footer: {
            Text("在账号中心可以绑定其他登录方式、查看设备或删除账号。退出只影响这台设备。")
        }
    }
}

/// Entry row for the Settings screen.
struct AccountSummaryRow: View {
    @EnvironmentObject private var account: AccountSession

    var body: some View {
        HStack(spacing: 12) {
            if account.isSignedIn {
                AccountInitialAvatar(name: account.profile?.displayName ?? "", size: 36)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Palette.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(account.isSignedIn ? (account.profile?.displayName ?? "已登录") : "登录账号")
                Text(account.isSignedIn ? account.membership.summary() : "用 Apple、邮箱、Google 或 GitHub 登录")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }
}

struct AccountInitialAvatar: View {
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
