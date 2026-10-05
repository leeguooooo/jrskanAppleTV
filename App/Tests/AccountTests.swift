import XCTest
#if os(tvOS)
@testable import JRKANTV
#else
@testable import JRKANiOS
#endif

/// Answers account-center requests from a per-test script, keyed by path.
final class StubAccountServer: URLProtocol {
    typealias Reply = (status: Int, body: String)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var log: [URLRequest] = []

    static func reset() {
        lock.withLock { replies = [:]; log = [] }
    }

    static func enqueue(_ path: String, status: Int = 200, _ body: String) {
        lock.withLock { replies[path, default: []].append((status, body)) }
    }

    static func requests(to path: String) -> [URLRequest] {
        lock.withLock { log.filter { $0.url?.path == path } }
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAccountServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            recorded.httpBody = data
        }
        let path = request.url?.path ?? ""
        let reply: Reply = Self.lock.withLock {
            Self.log.append(recorded)
            guard var queue = Self.replies[path], !queue.isEmpty else { return (404, #"{"statusMessage":"no stub"}"#) }
            let next = queue.removeFirst()
            // The last reply repeats, so a poll loop can keep getting it.
            Self.replies[path] = queue.isEmpty ? [next] : queue
            return next
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func tokenJSON(_ access: String, refresh: String = "r-new", expiresIn: Int = 600) -> String {
    #"{"token_type":"Bearer","access_token":"\#(access)","refresh_token":"\#(refresh)","id_token":"id","expires_in":\#(expiresIn)}"#
}

private let userInfoJSON = #"{"sub":"u1","email":"fan@example.com","name":"球迷"}"#
private let memberJSON = #"{"tenant_id":"tenant-jrkan","user_id":"u1","as_of":1,"active_entitlement_keys":["membership.all_apps"],"entitlements":[{"entitlement_key":"membership.all_apps","status":"granted","valid_to":4102444800}]}"#

private func formFields(_ request: URLRequest) -> [String: String] {
    let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        if parts.count == 2 { fields[parts[0]] = parts[1] }
    }
    return fields
}

final class AccountPrimitiveTests: XCTestCase {
    func testPKCEChallengeIsBase64URLSHA256OfVerifier() {
        // Cross-checked with Python: urlsafe_b64encode(sha256(verifier)) without padding.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mJ92K1qUdx9hR1j6ZD3J7nM-tvqsiA")
        XCTAssertEqual(pkce.challenge, "H0RovHRT5_KwoWVfSYAbboov_sw3NeQhXBpFuSLdx54")
        XCTAssertEqual(PKCE().verifier.count, 43)
    }

    func testAppleNonceIsLowercaseHexSHA256() {
        XCTAssertEqual(AppleNonce.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testPlaceholderEmailIsNeverShown() {
        let apple = AccountProfile(sub: "s", email: "apple-1a2b@users.account.invalid", name: nil, picture: nil)
        XCTAssertNil(apple.visibleEmail)
        XCTAssertEqual(apple.displayName, "leeguoo 账号")
        XCTAssertEqual(AccountProfile(sub: "s", email: "a@b.com", name: "", picture: nil).displayName, "a@b.com")
    }

    func testMembershipNeedsAMembershipKeyAndAnOpenPeriod() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(Membership(activeKeys: ["something.else"]).isActive(now: now))
        XCTAssertTrue(Membership(activeKeys: ["jrkan.premium"]).isActive(now: now))
        XCTAssertTrue(Membership(activeKeys: ["membership.all_apps"], validUntil: now.addingTimeInterval(1)).isActive(now: now))
        XCTAssertFalse(Membership(activeKeys: ["membership.all_apps"], validUntil: now).isActive(now: now))
        XCTAssertEqual(Membership().summary(now: now), "未开通会员")
        XCTAssertEqual(Membership(activeKeys: ["jrkan.premium"]).summary(now: now), "会员 · 长期有效")
    }

    func testTrialAndLapsedSummaries() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let trial = Membership(activeKeys: ["jrkan.premium"], validUntil: now.addingTimeInterval(86400 * 11.2), isTrial: true)
        XCTAssertEqual(trial.summary(now: now), "免费试用 · 剩余 12 天")
        XCTAssertEqual(trial.purchaseTitle(now: now), "开通会员 · ¥1.99/月")
        let paid = Membership(activeKeys: ["jrkan.premium"], validUntil: now.addingTimeInterval(86400 * 20), isTrial: false)
        XCTAssertEqual(paid.purchaseTitle(now: now), "续费 1 个月 · ¥1.99")
        XCTAssertEqual(Membership(lapsedAt: now.addingTimeInterval(-60)).summary(now: now), "会员已过期")
        // A cached trial that ran out while offline also reads as lapsed.
        XCTAssertEqual(Membership(activeKeys: ["jrkan.premium"], validUntil: now, isTrial: true).summary(now: now), "会员已过期")
    }

    func testOldCachedMembershipStillDecodes() throws {
        let old = #"{"activeKeys":["jrkan.premium"],"checkedAt":1000}"#
        let membership = try JSONDecoder().decode(Membership.self, from: Data(old.utf8))
        XCTAssertNil(membership.isTrial)
        XCTAssertNil(membership.lapsedAt)
    }

    func testAuthorizeURLCarriesPKCEAndRedirect() throws {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mJ92K1qUdx9hR1j6ZD3J7nM-tvqsiA")
        let url = AccountAPI(clientID: "leeguoo-jrkan-ios").authorizeURL(pkce: pkce, state: "s1")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.path, "/authorize")
        XCTAssertEqual(query["client_id"], "leeguoo-jrkan-ios")
        XCTAssertEqual(query["redirect_uri"], "com.leeguoo.jrskan.tv:/oauth/callback")
        XCTAssertEqual(query["code_challenge"], pkce.challenge)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], "s1")
    }
}

@MainActor
final class AccountSessionTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        StubAccountServer.reset()
    }

    private func api() -> AccountAPI {
        AccountAPI(session: StubAccountServer.session, clientID: "leeguoo-jrkan-tv", now: { [unowned self] in clock })
    }

    private func signedInStore(expiresAt: Date) -> MemoryAccountStore {
        MemoryAccountStore(StoredAccount(tokens: AuthTokens(accessToken: "a-old", refreshToken: "r-old", idToken: nil, expiresAt: expiresAt)))
    }

    func testAppleExchangeSendsRawNonceAndLoadsAccount() async throws {
        StubAccountServer.enqueue("/api/auth/apple/native", tokenJSON("a1"))
        StubAccountServer.enqueue("/userinfo", userInfoJSON)
        StubAccountServer.enqueue("/api/billing/entitlements", memberJSON)
        let store = MemoryAccountStore()
        let session = AccountSession(api: api(), store: store, now: { [unowned self] in clock })

        await session.run {
            try await session.api.signInWithApple(identityToken: "jwt", authorizationCode: "code", nonce: "raw-nonce",
                                                  givenName: "Lin", familyName: nil)
        }

        let request = try XCTUnwrap(StubAccountServer.requests(to: "/api/auth/apple/native").first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(body["nonce"], "raw-nonce")
        XCTAssertEqual(body["client_id"], "leeguoo-jrkan-tv")
        XCTAssertEqual(body["identity_token"], "jwt")
        XCTAssertNil(body["family_name"])
        XCTAssertTrue(session.isSignedIn)
        XCTAssertEqual(session.profile?.displayName, "球迷")
        XCTAssertTrue(session.isMember)
        XCTAssertEqual(store.stored?.tokens.refreshToken, "r-new")
        XCTAssertNil(session.lastError)
    }

    func testAccountExistsIsExplainedNotSignedIn() async {
        StubAccountServer.enqueue("/api/auth/apple/native", status: 409,
                                  #"{"error":"account_exists","error_description":"x","email":"fan@example.com"}"#)
        let session = AccountSession(api: api(), store: MemoryAccountStore())
        await session.run {
            try await session.api.signInWithApple(identityToken: "jwt", authorizationCode: nil, nonce: "n",
                                                  givenName: nil, familyName: nil)
        }
        XCTAssertFalse(session.isSignedIn)
        XCTAssertEqual(session.lastError, AccountError.accountExists(nil).errorDescription)
    }

    func testMembershipReadsTrialSourceAndLapsedRows() async throws {
        StubAccountServer.enqueue("/api/billing/entitlements", #"{"active_entitlement_keys":["jrkan.premium"],"entitlements":[{"entitlement_key":"jrkan.premium","status":"granted","valid_to":1007776000,"source":"promo","trial":true}],"expired_entitlements":[]}"#)
        let trial = try await api().membership(accessToken: "a")
        XCTAssertEqual(trial.isTrial, true)
        XCTAssertEqual(trial.validUntil, Date(timeIntervalSince1970: 1_007_776_000))

        StubAccountServer.reset()
        StubAccountServer.enqueue("/api/billing/entitlements", #"{"active_entitlement_keys":[],"entitlements":[],"expired_entitlements":[{"entitlement_key":"jrkan.premium","source":"promo","valid_to":999000}]}"#)
        let lapsed = try await api().membership(accessToken: "a")
        XCTAssertFalse(lapsed.isActive(now: clock))
        XCTAssertEqual(lapsed.lapsedAt, Date(timeIntervalSince1970: 999_000))
        XCTAssertEqual(lapsed.summary(now: clock), "会员已过期")
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        StubAccountServer.enqueue("/token", tokenJSON("a-fresh", refresh: "r-rotated"))
        let store = signedInStore(expiresAt: clock.addingTimeInterval(30))
        let session = AccountSession(api: api(), store: store, now: { [unowned self] in clock })

        async let first = session.validAccessToken()
        async let second = session.validAccessToken()
        let tokens = try await [first, second]

        XCTAssertEqual(tokens, ["a-fresh", "a-fresh"])
        let refreshes = StubAccountServer.requests(to: "/token")
        XCTAssertEqual(refreshes.count, 1)
        XCTAssertEqual(formFields(refreshes[0])["refresh_token"], "r-old")
        XCTAssertEqual(formFields(refreshes[0])["grant_type"], "refresh_token")
        XCTAssertEqual(store.stored?.tokens.refreshToken, "r-rotated")
    }

    func testFreshTokenIsUsedWithoutRefreshing() async throws {
        let session = AccountSession(api: api(), store: signedInStore(expiresAt: clock.addingTimeInterval(600)),
                                     now: { [unowned self] in clock })
        let token = try await session.validAccessToken()
        XCTAssertEqual(token, "a-old")
        XCTAssertTrue(StubAccountServer.requests(to: "/token").isEmpty)
    }

    func testRevokedRefreshTokenSignsOut() async {
        StubAccountServer.enqueue("/token", status: 400, #"{"error":"invalid_grant","error_description":"Invalid refresh token"}"#)
        let store = signedInStore(expiresAt: clock)
        let session = AccountSession(api: api(), store: store, now: { [unowned self] in clock })
        await session.refreshAccount()
        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(store.stored)
        XCTAssertEqual(session.lastError, "登录已过期，请重新登录。")
    }

    func testOfflineKeepsCachedMembership() async {
        let cached = StoredAccount(
            tokens: AuthTokens(accessToken: "a", refreshToken: "r", idToken: nil, expiresAt: clock.addingTimeInterval(600)),
            profile: AccountProfile(sub: "u1", email: nil, name: "球迷", picture: nil),
            membership: Membership(activeKeys: ["jrkan.premium"])
        )
        StubAccountServer.enqueue("/userinfo", status: 503, #"{"statusMessage":"down"}"#)
        let session = AccountSession(api: api(), store: MemoryAccountStore(cached), now: { [unowned self] in clock })
        await session.refreshAccount()
        XCTAssertTrue(session.isSignedIn)
        XCTAssertTrue(session.isMember)
    }

    func testSignOutClearsLocallyAndRevokesRefreshToken() async {
        StubAccountServer.enqueue("/revoke", "{}")
        let store = signedInStore(expiresAt: clock.addingTimeInterval(600))
        let session = AccountSession(api: api(), store: store)
        await session.signOut()
        XCTAssertFalse(session.isSignedIn)
        XCTAssertNil(store.stored)
        let revoke = StubAccountServer.requests(to: "/revoke")
        XCTAssertEqual(revoke.count, 1)
        XCTAssertEqual(formFields(revoke[0])["token"], "r-old")
    }
}

@MainActor
final class DeviceSignInTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var sleeps: [TimeInterval] = []

    override func setUp() {
        super.setUp()
        StubAccountServer.reset()
        sleeps = []
        StubAccountServer.enqueue("/device/code", #"{"device_code":"dc","user_code":"WDJB-MJHT","verification_uri":"https://account.leeguoo.com/device","verification_uri_complete":"https://account.leeguoo.com/device?user_code=WDJB-MJHT","expires_in":600,"interval":5}"#)
    }

    private func makeModel() -> (DeviceSignInModel, AccountSession) {
        let api = AccountAPI(session: StubAccountServer.session, clientID: "leeguoo-jrkan-tv", now: { [unowned self] in clock })
        let session = AccountSession(api: api, store: MemoryAccountStore(), now: { [unowned self] in clock })
        let model = DeviceSignInModel(sleep: { [unowned self] seconds in
            sleeps.append(seconds)
            clock = clock.addingTimeInterval(seconds)
        }, now: { [unowned self] in clock })
        return (model, session)
    }

    func testPollsThroughPendingAndSlowDownUntilApproved() async throws {
        StubAccountServer.enqueue("/token", status: 400, #"{"error":"authorization_pending"}"#)
        StubAccountServer.enqueue("/token", status: 400, #"{"error":"slow_down"}"#)
        StubAccountServer.enqueue("/token", tokenJSON("a1"))
        StubAccountServer.enqueue("/userinfo", userInfoJSON)
        StubAccountServer.enqueue("/api/billing/entitlements", memberJSON)
        let (model, session) = makeModel()

        await model.run(session: session)

        XCTAssertEqual(model.status, .completed)
        XCTAssertEqual(sleeps, [5, 5, 10])
        XCTAssertTrue(session.isSignedIn)
        XCTAssertTrue(session.isMember)
        let polls = StubAccountServer.requests(to: "/token")
        XCTAssertEqual(polls.count, 3)
        XCTAssertEqual(formFields(polls[0])["grant_type"], "urn:ietf:params:oauth:grant-type:device_code")
        XCTAssertEqual(formFields(polls[0])["device_code"], "dc")
        XCTAssertEqual(formFields(StubAccountServer.requests(to: "/device/code")[0])["client_id"], "leeguoo-jrkan-tv")
    }

    func testDeniedOnThePhone() async {
        StubAccountServer.enqueue("/token", status: 400, #"{"error":"access_denied"}"#)
        let (model, session) = makeModel()
        await model.run(session: session)
        XCTAssertEqual(model.status, .denied)
        XCTAssertFalse(session.isSignedIn)
    }

    func testStopsAtTheCodeDeadline() async {
        StubAccountServer.enqueue("/token", status: 400, #"{"error":"authorization_pending"}"#)
        let (model, session) = makeModel()
        await model.run(session: session)
        XCTAssertEqual(model.status, .expired)
        XCTAssertEqual(sleeps.reduce(0, +), 600)
    }

    func testServerSideExpiry() async {
        StubAccountServer.enqueue("/token", status: 400, #"{"error":"expired_token"}"#)
        let (model, session) = makeModel()
        await model.run(session: session)
        XCTAssertEqual(model.status, .expired)
    }
}
