import AuthenticationServices
import Foundation

/// The signed-in state the whole app reads. Signing in is optional: nothing
/// in the app needs an account except membership perks.
@MainActor
final class AccountSession: ObservableObject {
    @Published private(set) var stored: StoredAccount?
    @Published private(set) var isSigningIn = false
    @Published private(set) var isRefreshing = false
    /// The last failure worth showing next to the sign-in controls.
    @Published var lastError: String?

    var isSignedIn: Bool { stored != nil }
    var profile: AccountProfile? { stored?.profile }
    var membership: Membership { stored?.membership ?? Membership() }
    var isMember: Bool { membership.isActive(now: now()) }

    let api: AccountAPI
    private let store: AccountStoring
    private let now: () -> Date
    /// Debug mocks never talk to the server.
    private let offline: Bool
    private var refreshTask: Task<AuthTokens, Error>?

    init(api: AccountAPI = AccountAPI(), store: AccountStoring = KeychainAccountStore(),
         now: @escaping () -> Date = Date.init, offline: Bool = false) {
        self.api = api
        self.store = store
        self.now = now
        self.offline = offline
        stored = store.load()
    }

    // MARK: Lifecycle

    /// Launch and return-to-foreground: pick up membership changes made on
    /// another device or in the account center.
    func refreshIfStale(maxAge: TimeInterval = 30 * 60) async {
        guard let stored else { return }
        if let checked = stored.membership.checkedAt, now().timeIntervalSince(checked) < maxAge, stored.profile != nil { return }
        await refreshAccount()
    }

    func refreshAccount() async {
        guard stored != nil, !offline, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let token = try await validAccessToken()
            async let profile = api.userInfo(accessToken: token)
            async let membership = api.membership(accessToken: token)
            let (newProfile, newMembership) = try await (profile, membership)
            guard var current = stored else { return }
            current.profile = newProfile
            current.membership = newMembership
            persist(current)
        } catch let error as AccountError where error.endsSession {
            endSession(message: "登录已过期，请重新登录。")
        } catch {
            // Offline: the cached profile and membership keep working.
        }
    }

    /// Every API call goes through here; concurrent callers share one refresh
    /// because the server treats a reused refresh token as theft.
    func validAccessToken() async throws -> String {
        guard let current = stored else { throw AccountError.http(401, nil) }
        if !current.tokens.needsRefresh(now: now()) { return current.tokens.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }

        let used = current.tokens.refreshToken
        let task = Task { [api] in try await api.refresh(used) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let tokens = try await task.value
            // Signed out (or in as someone else) while the request was out.
            guard var latest = stored, latest.tokens.refreshToken == used else { throw AccountError.http(401, nil) }
            latest.tokens = tokens
            persist(latest)
            return tokens.accessToken
        } catch let error as AccountError where error.endsSession {
            if stored?.tokens.refreshToken == used { endSession(message: "登录已过期，请重新登录。") }
            throw error
        }
    }

    // MARK: Signing in

    /// Final step of every sign-in path (Apple, phone approval, browser).
    func complete(with tokens: AuthTokens) async {
        lastError = nil
        persist(StoredAccount(tokens: tokens))
        await refreshAccount()
    }

    func signInWithApple(_ result: Result<ASAuthorization, Error>, nonce: String) async {
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            lastError = "Apple 登录没有完成：\(error.localizedDescription)"
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityToken = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
                lastError = "Apple 没有返回身份凭证，请重试。"
                return
            }
            await run {
                try await self.api.signInWithApple(
                    identityToken: identityToken,
                    authorizationCode: credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) },
                    nonce: nonce,
                    givenName: credential.fullName?.givenName,
                    familyName: credential.fullName?.familyName
                )
            }
        }
    }

    /// Wraps a token exchange with the busy flag and error reporting.
    func run(_ exchange: @escaping () async throws -> AuthTokens) async {
        isSigningIn = true
        lastError = nil
        defer { isSigningIn = false }
        do {
            await complete(with: try await exchange())
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Signing out

    func signOut() async {
        guard let current = stored else { return }
        endSession(message: nil)
        await api.revoke(current.tokens.refreshToken)
    }

    private func endSession(message: String?) {
        store.clear()
        stored = nil
        lastError = message
    }

    private func persist(_ account: StoredAccount) {
        if !offline { store.save(account) }
        stored = account
    }
}

#if DEBUG
extension AccountSession {
    /// `-account-mock trial|member|expired|free` fakes a signed-in account so the screens
    /// can be checked on a simulator without a real sign-in.
    static func launchDefault() -> AccountSession {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-account-mock"), index + 1 < args.count else { return AccountSession() }
        let mode = args[index + 1]
        let active = mode == "member" || mode == "trial"
        let account = StoredAccount(
            tokens: AuthTokens(accessToken: "mock", refreshToken: "mock", idToken: nil, expiresAt: .distantFuture),
            profile: AccountProfile(sub: "mock", email: "viewer@example.com", name: "测试用户", picture: nil),
            membership: Membership(
                activeKeys: active ? ["jrkan.premium"] : [],
                validUntil: active ? Date().addingTimeInterval(86400 * (mode == "trial" ? 76.5 : 200)) : nil,
                checkedAt: Date(),
                isTrial: mode == "trial",
                lapsedAt: mode == "expired" ? Date().addingTimeInterval(-86400 * 3) : nil
            )
        )
        return AccountSession(store: MemoryAccountStore(account), offline: true)
    }
}
#else
extension AccountSession {
    static func launchDefault() -> AccountSession { AccountSession() }
}
#endif

extension Membership {
    /// One line for the account screens, e.g. "免费试用 · 剩余 12 天".
    func summary(now: Date = Date()) -> String {
        guard isActive(now: now) else { return hasLapsed(now: now) ? "会员已过期" : "未开通会员" }
        guard let validUntil else { return "会员 · 长期有效" }
        if isTrial == true { return "免费试用 · 剩余 \(daysLeft(now: now)) 天" }
        return "会员 · 有效期至 \(validUntil.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))"
    }

    func hasLapsed(now: Date) -> Bool {
        lapsedAt != nil || (validUntil.map { $0 <= now } ?? false)
    }

    /// Partial days count as a day: "剩余 0 天" while it still works reads as a bug.
    func daysLeft(now: Date) -> Int {
        guard let validUntil else { return 0 }
        return max(0, Int((validUntil.timeIntervalSince(now) / 86400).rounded(.up)))
    }

    /// The purchase button's title for the current state.
    func purchaseTitle(now: Date = Date()) -> String {
        isActive(now: now) && isTrial != true ? "续费 3 个月 · ¥5" : "开通会员 · \(AccountConfig.priceLabel)"
    }
}
