import Foundation

#if canImport(Security)
import Security
#endif

/// The cmux control-socket password, as the join arm needs it.
///
/// A protocol rather than a concrete type because the live implementation talks
/// to the login keychain, and no unit test may: a suite that writes real
/// keychain items either prompts the developer or silently mutates their
/// machine's secrets. Every test injects `InMemoryCmuxPasswordStore` instead.
public protocol CmuxPasswordStoring: Sendable {
    /// The stored password, or nil when none is stored (or the read failed —
    /// the two are the same thing to a caller that can only abstain).
    func password() -> String?
    /// Stores `password`, or removes the item when it is nil/empty.
    /// Returns false on any keychain failure so the UI can say so.
    @discardableResult
    func setPassword(_ password: String?) -> Bool
}

/// Validation shared by every store, applied on the way IN.
///
/// cmux's password is a user-typed shared secret that we put into a JSON
/// request line. JSON escaping already makes framing safe, but a control
/// character in a password is never intentional and a pasted multi-line blob is
/// a paste accident, not a secret — refusing both at the door keeps the failure
/// at the settings field, where the user can see it, instead of turning into an
/// unexplained auth rejection later.
enum CmuxPasswordValidation {
    /// UTF-8 byte cap. Generously above anything a human types; a value near it
    /// is not a password.
    static let maxPasswordBytes = 256

    /// Trims surrounding whitespace and rejects empty, oversized, or
    /// control-character-bearing values. Returns nil for "nothing to store".
    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count <= maxPasswordBytes else { return nil }
        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { return nil }
        return trimmed
    }
}

/// The keychain item a store reads and writes, kept behind a seam so the
/// SecItem calls exist in exactly one place and the tests exercise everything
/// above them.
protocol CmuxKeychainBackend: Sendable {
    func read(service: String, account: String) -> Data?
    func write(_ data: Data, service: String, account: String) -> Bool
    func delete(service: String, account: String) -> Bool
}

/// Login-keychain generic password. The password is a shared secret for a
/// loopback socket, so it belongs in the keychain rather than in
/// `UserDefaults`, where every process running as the user can read it out of a
/// plist.
public struct CmuxSocketPasswordStore: CmuxPasswordStoring {
    static let defaultService = "com.localvoxtral.app.cmux-socket"
    static let defaultAccount = "automation-socket-password"

    private let service: String
    private let account: String
    private let backend: any CmuxKeychainBackend

    init(
        service: String = CmuxSocketPasswordStore.defaultService,
        account: String = CmuxSocketPasswordStore.defaultAccount,
        backend: any CmuxKeychainBackend = SecItemCmuxKeychainBackend()
    ) {
        self.service = service
        self.account = account
        self.backend = backend
    }

    public func password() -> String? {
        guard let data = backend.read(service: service, account: account),
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        // Re-normalized on the way out too: an item written by an older build
        // (or by hand in Keychain Access) is not this build's input.
        return CmuxPasswordValidation.normalized(value)
    }

    @discardableResult
    public func setPassword(_ password: String?) -> Bool {
        guard let normalized = CmuxPasswordValidation.normalized(password) else {
            // Nil, empty, or rejected: the stored secret goes away rather than
            // silently keeping the previous one. A user who clears the field
            // means "stop using a password", and a rejected value must not
            // leave the old one quietly in force.
            let removed = backend.delete(service: service, account: account)
            Log.claudeContext.info(
                "cmux socket password cleared (removed: \(removed, privacy: .public))"
            )
            return removed
        }
        let stored = backend.write(Data(normalized.utf8), service: service, account: account)
        // Never the value, never its length: a length is a real hint about a
        // secret and the log is world-readable to anything with Console.
        Log.claudeContext.info("cmux socket password stored: \(stored, privacy: .public)")
        return stored
    }
}

/// The live keychain. `kSecAttrAccessibleWhenUnlocked` on purpose: the join arm
/// only ever runs while the user is at the machine dictating, so there is no
/// reason for this secret to be readable while the Mac is locked.
struct SecItemCmuxKeychainBackend: CmuxKeychainBackend {
    init() {}

    func read(service: String, account: String) -> Data? {
        #if canImport(Security)
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Log.claudeContext.info(
                    "cmux keychain read failed: OSStatus \(status, privacy: .public)"
                )
            }
            return nil
        }
        return item as? Data
        #else
        return nil
        #endif
    }

    func write(_ data: Data, service: String, account: String) -> Bool {
        #if canImport(Security)
        let query = Self.baseQuery(service: service, account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            Log.claudeContext.info(
                "cmux keychain update failed: OSStatus \(updateStatus, privacy: .public)"
            )
            return false
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Log.claudeContext.info(
                "cmux keychain add failed: OSStatus \(addStatus, privacy: .public)"
            )
        }
        return addStatus == errSecSuccess
        #else
        return false
        #endif
    }

    func delete(service: String, account: String) -> Bool {
        #if canImport(Security)
        let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        // Nothing stored is the state the caller asked for, so it is a success.
        if status != errSecSuccess, status != errSecItemNotFound {
            Log.claudeContext.info(
                "cmux keychain delete failed: OSStatus \(status, privacy: .public)"
            )
            return false
        }
        return true
        #else
        return false
        #endif
    }

    #if canImport(Security)
    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
    #endif
}
