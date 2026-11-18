import Foundation
import KanCore
import Security

/// A keychain call that failed, by OSStatus. Never carries the key.
public struct KeychainError: Error, LocalizedError, Sendable, Equatable {
    public enum Operation: String, Sendable {
        case save, delete
    }

    public let operation: Operation
    public let status: OSStatus

    public init(operation: Operation, status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    /// The system's description of `status`, e.g. "The user name or passphrase you entered is not correct."
    public var statusMessage: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"
    }

    public var errorDescription: String? {
        switch operation {
        case .save: return "Couldn't save the API key in the keychain: \(statusMessage) (OSStatus \(status))."
        case .delete: return "Couldn't remove the API key from the keychain: \(statusMessage) (OSStatus \(status))."
        }
    }
}

/// The OpenAI API key in the login keychain, as a generic password (service
/// "com.nahian.Kan.openai", account "default", shown in Keychain Access as "Kan — OpenAI API key").
///
/// The legacy file keychain on purpose: the data protection keychain needs a provisioning profile
/// and access groups, and Kan is self-signed without either. Without a Team ID, the keychain ties
/// the item to the build that saved it (its code hash), so a new build's first read makes macOS ask
/// whether Kan may use “Kan — OpenAI API key” (with the login password), and a one-time Allow would
/// leave it asking at every launch. So after its first successful read the store saves the same key
/// again, which ties the item to the running build without asking: one ask per update of Kan, then
/// never again for that build. A read can wait for that ask, which is why these calls must stay off
/// the main thread; they run one at a time.
public final class KeychainAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    public static let defaultService = "com.nahian.Kan.openai"
    public static let defaultAccount = "default"
    public static let defaultLabel = "Kan — OpenAI API key"

    public let service: String
    public let account: String
    public let label: String

    private let lock = NSLock()
    /// This store wrote the item (a save, or the re-save after the first read), so it's tied to the
    /// running build.
    private var savedByThisBuild = false

    /// Tests pass a throwaway `service`; the app uses the defaults.
    public init(service: String = KeychainAPIKeyStore.defaultService, account: String = KeychainAPIKeyStore.defaultAccount,
                label: String = KeychainAPIKeyStore.defaultLabel) {
        self.service = service
        self.account = account
        self.label = label
    }

    public func loadKey() -> String? {
        lock.withLock {
            var query = itemQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
                    KanLog.warning("The OpenAI API key in the keychain isn't readable text", category: "ai")
                    return nil
                }
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                if !savedByThisBuild { resave(data) }
                return trimmed
            case errSecItemNotFound:
                return nil
            default:
                KanLog.warning("Couldn't read the OpenAI API key from the keychain (OSStatus \(status))", category: "ai")
                return nil
            }
        }
    }

    /// Replaces the saved key (update, or add when there is none). Surrounding whitespace is dropped.
    public func saveKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainError(operation: .save, status: errSecParam) }
        let data = Data(trimmed.utf8)
        try lock.withLock {
            let changes: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
            let updated = SecItemUpdate(itemQuery as CFDictionary, changes as CFDictionary)
            switch updated {
            case errSecSuccess:
                break
            case errSecItemNotFound:
                var item = itemQuery
                item[kSecValueData as String] = data
                item[kSecAttrLabel as String] = label
                let added = SecItemAdd(item as CFDictionary, nil)
                guard added == errSecSuccess else { throw KeychainError(operation: .save, status: added) }
            default:
                throw KeychainError(operation: .save, status: updated)
            }
            savedByThisBuild = true
        }
    }

    /// Removes the key; nothing saved is fine.
    public func deleteKey() throws {
        try lock.withLock {
            savedByThisBuild = false
            // The file keychain may delete one match per call; there should be only one, but a stray
            // duplicate must not outlive "Remove".
            for _ in 0..<8 {
                let status = SecItemDelete(itemQuery as CFDictionary)
                switch status {
                case errSecSuccess: continue
                case errSecItemNotFound: return
                default: throw KeychainError(operation: .delete, status: status)
                }
            }
        }
    }

    /// Writes the key just read back unchanged, once: an update made by this build ties the item to
    /// it, so the next launches read it without asking. Only an update (a deleted item stays deleted);
    /// a failure changes nothing and is logged by OSStatus. Runs with `lock` held.
    private func resave(_ data: Data) {
        savedByThisBuild = true
        let status = SecItemUpdate(itemQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess {
            KanLog.debug("Saved the OpenAI API key again, for this build of Kan", category: "ai")
        } else {
            KanLog.warning("Couldn't save the OpenAI API key again for this build (OSStatus \(status))", category: "ai")
        }
    }

    /// Identifies the item. No `kSecUseDataProtectionKeychain` and no access group: the login
    /// (file) keychain.
    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// A key kept in memory, for tests and the app's self-test (never the keychain).
public final class InMemoryAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(key: String? = nil) {
        self.key = key
    }

    public func loadKey() -> String? {
        lock.withLock { key }
    }

    public func saveKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainError(operation: .save, status: errSecParam) }
        lock.withLock { self.key = trimmed }
    }

    public func deleteKey() throws {
        lock.withLock { key = nil }
    }
}
