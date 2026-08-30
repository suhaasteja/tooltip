import Foundation
import Security

/// Stores the API key in the login keychain as a generic password.
///
/// Never `UserDefaults`: that file is world-readable plist data.
public struct KeychainStore {

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case malformedData
    }

    /// Keychain service name. Distinct per bundle so a test run cannot stomp on
    /// a real stored key.
    public let service: String
    public let account: String

    /// Opt into the data protection keychain (the iOS-style one) instead of the
    /// legacy file-based login keychain.
    ///
    /// This is the difference between "no prompts, ever" and "a login-password
    /// dialog whenever the signing identity changes". The legacy keychain guards
    /// each item with an ACL listing the applications allowed to read it, and an
    /// app whose code signature has changed is, correctly, a different
    /// application -- so it asks. The data protection keychain has no ACLs: access
    /// is decided by the app's access group, derived from its team identifier.
    ///
    /// The catch is that it *requires* a team identifier. An ad-hoc signature has
    /// none, so every call fails with `errSecMissingEntitlement` (-34018). Hence
    /// the flag rather than a hard switch: it can only be turned on for builds
    /// signed with a real identity. See NOTES.md.
    public let useDataProtection: Bool

    public init(
        service: String = "com.yourname.AskAI",
        account: String = "anthropic-api-key",
        useDataProtection: Bool = false
    ) {
        self.service = service
        self.account = account
        self.useDataProtection = useDataProtection
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// Reads the stored secret, or `nil` if there isn't one.
    public func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8)
            else { throw KeychainError.malformedData }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Writes the secret, replacing any existing one.
    ///
    /// Uses add-then-update-on-duplicate rather than blind delete-and-add so a
    /// failed write cannot leave the user with no key at all.
    public func save(_ secret: String) throws {
        guard let data = secret.data(using: .utf8) else { throw KeychainError.malformedData }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        // Available whenever the device is unlocked; not synced to iCloud.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: data] as CFDictionary
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes the secret. Deleting a nonexistent item is not an error.
    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
