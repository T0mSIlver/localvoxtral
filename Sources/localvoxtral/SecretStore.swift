import Foundation
import Synchronization

/// The three API keys this app holds. Raw values are the Keychain ACCOUNT
/// names of the generic-password items under
/// `KeychainSecretStore.defaultService`.
///
/// They are deliberately NOT the `settings.*` UserDefaults key names the
/// secrets used to live under. Two namespaces spelled alike are two namespaces
/// someone eventually confuses — and a rename here orphans a user's stored key
/// exactly the way renaming a defaults key would, so these strings are
/// permanent.
enum SecretKey: String, CaseIterable, Sendable {
    /// External URL mode's realtime bearer token (`SettingsStore.apiKey`).
    case realtimeAPIKey
    /// External URL mode's polishing bearer token.
    case llmPolishingAPIKey
    /// The one Mistral account key, shared by both Mistral engines.
    case mistralAPIKey
}

/// Where a secret lives. `nil` and the empty string both mean "no secret":
/// storing either deletes the item, so a cleared field never leaves a stale
/// key behind.
protocol SecretStoring: Sendable {
    func secret(for key: SecretKey) throws -> String?
    func setSecret(_ value: String?, for key: SecretKey) throws
}

/// A secret-store operation that did not complete. Carries the underlying
/// `OSStatus` so the log line is actionable (`errSecInteractionNotAllowed` —
/// a locked keychain — reads very differently from `errSecAuthFailed`).
struct SecretStoreError: Error, Equatable, CustomStringConvertible {
    enum Operation: String, Sendable {
        case read
        case write
        case delete
    }

    let operation: Operation
    let key: SecretKey
    /// `OSStatus`. Typed as `Int32` so this stays usable from tests that fake
    /// a failure without importing Security.
    let status: Int32
    /// `SecCopyErrorMessageString`, when the system had one.
    let message: String?

    var description: String {
        let detail = message.map { ": \($0)" } ?? ""
        return "\(operation.rawValue) of \(key.rawValue) failed (OSStatus \(status))\(detail)"
    }
}

/// Process-local secret store for tests and previews. Never touches the real
/// keychain, which is the whole point: see `KeychainSecretStore.init`.
final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let storage: Mutex<[SecretKey: String]>

    init(_ initial: [SecretKey: String] = [:]) {
        storage = Mutex(initial)
    }

    func secret(for key: SecretKey) throws -> String? {
        storage.withLock { $0[key] }
    }

    func setSecret(_ value: String?, for key: SecretKey) throws {
        storage.withLock { storage in
            guard let value, !value.isEmpty else {
                storage.removeValue(forKey: key)
                return
            }
            storage[key] = value
        }
    }

    /// Everything currently held, for assertions that a write landed in the
    /// store rather than in UserDefaults.
    var snapshot: [SecretKey: String] {
        storage.withLock { $0 }
    }
}
