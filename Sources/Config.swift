import Foundation
import Security

struct AppConfig: Equatable {
    var feedURL: String
    var authHeader: String?
}

/// Feed URL lives in UserDefaults (not secret); the Authorization value lives in the Keychain.
enum ConfigStore {
    private static let feedURLKey = "feedURL"
    static let debugUnlockedKey = "debugUnlocked"
    private static let authAccount = "authHeader"
    // Keys used by the pre-v0.2 builds (both in UserDefaults).
    private static let legacyRootURLKey = "rootURL"
    private static let legacyAuthKey = "authHeader"

    static func load() -> AppConfig? {
        migrateIfNeeded()
        let url = UserDefaults.standard.string(forKey: feedURLKey)?.trimmed ?? ""
        guard !url.isEmpty else { return nil }
        let auth = Keychain.get(authAccount)?.trimmed
        return AppConfig(feedURL: url, authHeader: (auth?.isEmpty ?? true) ? nil : auth)
    }

    static func save(_ config: AppConfig) {
        UserDefaults.standard.set(config.feedURL.trimmed, forKey: feedURLKey)
        let auth = config.authHeader?.trimmed ?? ""
        if auth.isEmpty {
            Keychain.delete(authAccount)
        } else {
            Keychain.set(auth, for: authAccount)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: feedURLKey)
        Keychain.delete(authAccount)
    }

    static var debugUnlocked: Bool {
        get { UserDefaults.standard.bool(forKey: debugUnlockedKey) }
        set { UserDefaults.standard.set(newValue, forKey: debugUnlockedKey) }
    }

    // How often to check the feed. Drives the background-refresh request (best-effort,
    // clamped to ≥15 min by iOS reality), the launch staleness check, and the foreground
    // polling loop (which honors short debug intervals exactly while the app is open).
    static let syncIntervalKey = "syncIntervalSeconds"
    static let defaultSyncInterval: TimeInterval = 6 * 60 * 60

    static var syncInterval: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: syncIntervalKey)
            return value > 0 ? value : defaultSyncInterval
        }
        set { UserDefaults.standard.set(newValue, forKey: syncIntervalKey) }
    }

    private static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: feedURLKey) == nil, let oldURL = defaults.string(forKey: legacyRootURLKey) {
            defaults.set(oldURL, forKey: feedURLKey)
            defaults.removeObject(forKey: legacyRootURLKey)
        }
        if let oldAuth = defaults.string(forKey: legacyAuthKey) {
            if Keychain.get(authAccount) == nil, !oldAuth.trimmed.isEmpty {
                Keychain.set(oldAuth.trimmed, for: authAccount)
            }
            defaults.removeObject(forKey: legacyAuthKey)
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Minimal generic-password Keychain wrapper. `AfterFirstUnlock` so background refresh can read it.
enum Keychain {
    private static var service: String { Bundle.main.bundleIdentifier ?? "workout-feed" }

    static func set(_ value: String, for account: String) {
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
