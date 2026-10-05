import Foundation
import Security

/// What survives a relaunch: the tokens plus the last profile and membership
/// seen, so the account screen and perks work before the network answers.
struct StoredAccount: Codable, Equatable {
    var tokens: AuthTokens
    var profile: AccountProfile?
    var membership = Membership()
}

protocol AccountStoring: AnyObject {
    func load() -> StoredAccount?
    func save(_ account: StoredAccount)
    func clear()
}

/// One generic-password item in the Keychain. Tokens never touch
/// UserDefaults: those are plain files in the app container and end up in
/// device backups.
final class KeychainAccountStore: AccountStoring {
    private let service: String

    init(service: String = "com.leeguoo.jrskan.account") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
            // Mac Catalyst would otherwise use the legacy file keychain.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func load() -> StoredAccount? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredAccount.self, from: data)
    }

    func save(_ account: StoredAccount) {
        guard let data = try? JSONEncoder().encode(account) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Background refresh after a reboot must still be able to read it.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

final class MemoryAccountStore: AccountStoring {
    private(set) var stored: StoredAccount?

    init(_ stored: StoredAccount? = nil) {
        self.stored = stored
    }

    func load() -> StoredAccount? { stored }
    func save(_ account: StoredAccount) { stored = account }
    func clear() { stored = nil }
}
