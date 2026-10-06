import CryptoKit
import Foundation

/// The leeguoo account center (account.leeguoo.com) is the one identity
/// provider for every app; JRKAN is just another OIDC client of it. Accounts,
/// sign-in methods and memberships live there — the app only keeps tokens.
enum AccountConfig {
    static let issuer = URL(string: "https://account.leeguoo.com")!
    #if os(tvOS)
    static let clientID = "leeguoo-jrkan-tv"
    #else
    static let clientID = "leeguoo-jrkan-ios"
    #endif
    static let callbackScheme = "com.leeguoo.jrskan.tv"
    static let redirectURI = "com.leeguoo.jrskan.tv:/oauth/callback"
    static let scope = "openid profile email"
    /// Either the cross-app membership or a JRKAN-only plan unlocks the perks.
    static let membershipKeys: Set<String> = ["membership.all_apps", "jrkan.premium"]
    static let manageURL = issuer.appending(path: "account")
    /// Hosted purchase page: signs in if needed, then hands off to 爱发电
    /// (WeChat Pay / Alipay). Payment never happens inside the app.
    static let membershipURL = issuer.appending(path: "membership/jrkan")
    static let priceLabel = "¥5 / 3 个月"
    static let deviceURLText = "account.leeguoo.com/device"
}

struct AuthTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var idToken: String?
    var expiresAt: Date

    /// A minute of slack so a token never expires between check and use.
    func needsRefresh(now: Date) -> Bool { now >= expiresAt.addingTimeInterval(-60) }
}

struct AccountProfile: Codable, Equatable {
    var sub: String
    var email: String?
    var name: String?
    var picture: String?

    /// Apple and WeChat sign-ups that shared no email get a placeholder
    /// address on this domain; it means nothing to the viewer.
    var visibleEmail: String? {
        guard let email, !email.hasSuffix("@users.account.invalid") else { return nil }
        return email
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return visibleEmail ?? "leeguoo 账号"
    }
}

struct Membership: Codable, Equatable {
    var activeKeys: Set<String> = []
    /// nil with active keys means it never lapses.
    var validUntil: Date?
    var checkedAt: Date?
    /// Only the free first-use trial is behind the active membership.
    /// Optional so caches written by older builds still decode.
    var isTrial: Bool?
    /// When the last membership ran out, if it did.
    var lapsedAt: Date?

    func isActive(now: Date) -> Bool {
        guard !activeKeys.isDisjoint(with: AccountConfig.membershipKeys) else { return false }
        return validUntil.map { $0 > now } ?? true
    }
}

struct DeviceAuthorization: Decodable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let verificationURIComplete: URL?
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete", expiresIn = "expires_in", interval
    }
}

enum AccountError: Error, Equatable, LocalizedError {
    /// OAuth error body (`{ error, error_description }`), e.g. authorization_pending.
    case oauth(String, String?)
    /// The Apple ID's email already belongs to an account that never linked Apple.
    case accountExists(String?)
    case http(Int, String?)
    case network(String)
    case invalidResponse

    /// The refresh token is gone for good; only a new sign-in helps.
    var endsSession: Bool {
        switch self {
        case .oauth(let code, _): return code == "invalid_grant"
        case .http(let status, _): return status == 401
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .accountExists:
            return "这个 Apple ID 的邮箱已经注册过账号。请先用原来的方式登录，再到账号中心「登录方式」里绑定 Apple。"
        case .oauth(let code, let description):
            return description ?? code
        case .http(let status, let message):
            return message ?? "账号中心返回 \(status)"
        case .network:
            return "连不上账号中心，请检查网络后重试。"
        case .invalidResponse:
            return "账号中心暂时不可用，请稍后再试。"
        }
    }
}

/// Thin HTTP layer over the account center's OIDC endpoints and the native
/// sign-in exchanges. Stateless: tokens are passed in and handed back.
struct AccountAPI {
    var session: URLSession = .shared
    var issuer: URL = AccountConfig.issuer
    var clientID: String = AccountConfig.clientID
    var now: () -> Date = Date.init

    // MARK: Sign-in exchanges

    func signInWithApple(identityToken: String, authorizationCode: String?, nonce: String,
                         givenName: String?, familyName: String?) async throws -> AuthTokens {
        var body: [String: String] = ["client_id": clientID, "identity_token": identityToken, "nonce": nonce]
        body["authorization_code"] = authorizationCode
        body["given_name"] = givenName
        body["family_name"] = familyName
        var request = URLRequest(url: issuer.appending(path: "api/auth/apple/native"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await tokens(from: request)
    }

    func requestDeviceCode() async throws -> DeviceAuthorization {
        let request = form("device/code", ["client_id": clientID, "scope": AccountConfig.scope])
        return try decode(DeviceAuthorization.self, from: try await send(request))
    }

    /// Throws `.oauth("authorization_pending")` until the phone approves.
    func pollDeviceToken(deviceCode: String) async throws -> AuthTokens {
        try await tokens(from: form("token", [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": deviceCode,
            "client_id": clientID,
        ]))
    }

    func authorizeURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: issuer.appending(path: "authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: AccountConfig.redirectURI),
            URLQueryItem(name: "scope", value: AccountConfig.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    func exchangeCode(_ code: String, pkce: PKCE) async throws -> AuthTokens {
        try await tokens(from: form("token", [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": AccountConfig.redirectURI,
            "code_verifier": pkce.verifier,
            "client_id": clientID,
        ]))
    }

    // MARK: Session

    /// Refresh tokens rotate on every use; the old one is dead once this returns.
    func refresh(_ refreshToken: String) async throws -> AuthTokens {
        var tokens = try await tokens(from: form("token", [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]))
        if tokens.refreshToken.isEmpty { tokens.refreshToken = refreshToken }
        return tokens
    }

    /// RFC 7009 answers 200 for anything, so there is nothing to report.
    func revoke(_ token: String) async {
        let request = form("revoke", ["token": token, "token_type_hint": "refresh_token", "client_id": clientID])
        _ = try? await send(request)
    }

    func userInfo(accessToken: String) async throws -> AccountProfile {
        var request = URLRequest(url: issuer.appending(path: "userinfo"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try decode(AccountProfile.self, from: try await send(request))
    }

    func membership(accessToken: String) async throws -> Membership {
        var request = URLRequest(url: issuer.appending(path: "api/billing/entitlements"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let payload = try decode(EntitlementsPayload.self, from: try await send(request))
        let relevant = payload.entitlements.filter {
            $0.status == "granted" && AccountConfig.membershipKeys.contains($0.entitlementKey)
        }
        let validUntil: Date? = relevant.contains { $0.validTo == nil } ? nil
            : relevant.compactMap(\.validTo).max().map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let lapsed = (payload.expiredEntitlements ?? [])
            .filter { AccountConfig.membershipKeys.contains($0.entitlementKey) }
            .compactMap(\.validTo).max()
        return Membership(
            activeKeys: Set(payload.activeEntitlementKeys),
            validUntil: validUntil,
            checkedAt: now(),
            isTrial: !relevant.isEmpty && relevant.allSatisfy { $0.trial == true },
            lapsedAt: lapsed.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    // MARK: Plumbing

    private struct TokenPayload: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Int?
    }

    private struct EntitlementsPayload: Decodable {
        struct Row: Decodable {
            let entitlementKey: String
            let status: String
            let validTo: Int?
            /// The free first-use trial (the server marks it, source stays "promo").
            let trial: Bool?
            enum CodingKeys: String, CodingKey { case entitlementKey = "entitlement_key", status, validTo = "valid_to", trial }
        }
        struct Lapsed: Decodable {
            let entitlementKey: String
            let validTo: Int?
            enum CodingKeys: String, CodingKey { case entitlementKey = "entitlement_key", validTo = "valid_to" }
        }
        let activeEntitlementKeys: [String]
        let entitlements: [Row]
        let expiredEntitlements: [Lapsed]?
        enum CodingKeys: String, CodingKey {
            case activeEntitlementKeys = "active_entitlement_keys", entitlements, expiredEntitlements = "expired_entitlements"
        }
    }

    private struct ErrorPayload: Decodable {
        let error: String?
        let error_description: String?
        let email: String?
        /// h3's createError shape.
        let statusMessage: String?
        let message: String?
    }

    private func tokens(from request: URLRequest) async throws -> AuthTokens {
        let payload = try decode(TokenPayload.self, from: try await send(request))
        return AuthTokens(
            accessToken: payload.access_token,
            refreshToken: payload.refresh_token ?? "",
            idToken: payload.id_token,
            expiresAt: now().addingTimeInterval(TimeInterval(payload.expires_in ?? 600))
        )
    }

    /// An HTML page (proxy, captive portal, an endpoint not deployed yet) is
    /// not worth showing the viewer as a JSON decoding error.
    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw AccountError.invalidResponse }
    }

    private func form(_ path: String, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: issuer.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AccountError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AccountError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(ErrorPayload.self, from: data)
            if body?.error == "account_exists" { throw AccountError.accountExists(body?.email) }
            if let code = body?.error { throw AccountError.oauth(code, body?.error_description) }
            if body == nil { throw http.statusCode == 401 ? AccountError.http(401, nil) : AccountError.invalidResponse }
            throw AccountError.http(http.statusCode, body?.statusMessage ?? body?.message)
        }
        return data
    }
}

/// RFC 7636 proof key for the browser sign-in.
struct PKCE: Equatable {
    let verifier: String
    let challenge: String

    init(verifier: String = PKCE.randomURLSafe(bytes: 32)) {
        self.verifier = verifier
        challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    static func randomURLSafe(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64URLEncodedString()
    }
}

/// Sign in with Apple wants the SHA-256 of a one-time nonce in the request;
/// the server gets the raw value and checks it against the identity token.
enum AppleNonce {
    static func make() -> String { PKCE.randomURLSafe(bytes: 32) }

    static func sha256(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
