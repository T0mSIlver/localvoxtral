import Foundation
import Security
import Synchronization

/// The login-keychain backing for the three API keys.
///
/// Items are legacy (file-based) generic passwords: `kSecClassGenericPassword`
/// under one service, one account per `SecretKey`. Two attribute choices are
/// load-bearing and must not be "modernised" casually:
///
/// - `kSecUseDataProtectionKeychain` is NOT set. The data-protection keychain
///   partitions items by team identifier, which the ad-hoc and Developer-ID
///   builds of this app do not share; an item written by one build would be
///   invisible to the next.
/// - `kSecAttrSynchronizable` is explicitly `false`, so a user's API keys never
///   ride iCloud Keychain to their other devices.
///
/// `kSecAttrAccessible` is left unset for the same reason: it is a
/// data-protection attribute, and the login keychain's own unlock state is what
/// gates these items.
final class KeychainSecretStore: SecretStoring, @unchecked Sendable {
    /// Generic-password service shared by all three keys. Stated in
    /// `docs/under-the-hood.md`; changing it orphans every stored key.
    static let defaultService = "com.localvoxtral.api-keys"

    private let service: String
    /// Serialises the read-modify-write inside `setSecret` (probe, then add or
    /// update). The keychain itself is thread-safe per call, but the pair is
    /// not, and two writers racing the probe would double-add.
    private let lock = Mutex<Bool>(false)

    /// - Parameter allowUseUnderXCTest: escape hatch for
    ///   `KeychainSecretStoreIntegrationTests`, the one suite that is supposed
    ///   to touch the real keychain (and cleans up after itself). Everything
    ///   else must inject `InMemorySecretStore`.
    init(service: String = KeychainSecretStore.defaultService, allowUseUnderXCTest: Bool = false) {
        #if DEBUG
        if !allowUseUnderXCTest, NSClassFromString("XCTestCase") != nil {
            preconditionFailure(
                """
                KeychainSecretStore must not be constructed under XCTest: it would write \
                API keys into the test runner's login keychain. Pass \
                `secretStore: InMemorySecretStore()` to SettingsStore(...) instead.
                """
            )
        }
        #endif
        self.service = service
    }

    func secret(for key: SecretKey) throws -> String? {
        try lock.withLock { _ in try load(key) }
    }

    func setSecret(_ value: String?, for key: SecretKey) throws {
        try lock.withLock { _ in
            guard let value, !value.isEmpty else {
                try delete(key)
                return
            }
            try store(Data(value.utf8), for: key)
        }
    }

    // MARK: - Keychain

    private func baseQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func load(_ key: SecretKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard
                let data = item as? Data,
                let value = String(data: data, encoding: .utf8)
            else {
                // An item exists but is not the UTF-8 string we wrote. Reporting
                // that as "no key set" would send the user hunting for a
                // configuration bug that is really a corrupt item.
                throw failure(.read, key, errSecDecode)
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw failure(.read, key, status)
        }
    }

    private func store(_ data: Data, for key: SecretKey) throws {
        let query = baseQuery(for: key)
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        switch existing {
        case errSecSuccess:
            let status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard status == errSecSuccess else { throw failure(.write, key, status) }
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw failure(.write, key, status) }
        default:
            throw failure(.write, key, existing)
        }
    }

    private func delete(_ key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw failure(.delete, key, status)
        }
    }

    /// Builds the thrown error AND logs it. Every keychain status this app does
    /// not expect gets one loud line naming the operation, the account, and the
    /// OSStatus — never the secret.
    private func failure(
        _ operation: SecretStoreError.Operation,
        _ key: SecretKey,
        _ status: OSStatus
    ) -> SecretStoreError {
        let message = SecCopyErrorMessageString(status, nil) as String?
        let error = SecretStoreError(
            operation: operation,
            key: key,
            status: Int32(status),
            message: message
        )
        Log.secrets.error(
            "Keychain \(operation.rawValue, privacy: .public) of \(key.rawValue, privacy: .public) in service \(self.service, privacy: .public) failed: OSStatus \(status, privacy: .public) (\(message ?? "no message", privacy: .public))"
        )
        return error
    }
}
