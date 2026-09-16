import Foundation
import Security
import XCTest

@testable import localvoxtral

/// The one suite that talks to the REAL login keychain.
///
/// Everything else injects `InMemorySecretStore` — `KeychainSecretStore.init`
/// traps under XCTest precisely so a forgotten call site cannot write a key
/// into the runner's keychain. This suite passes `allowUseUnderXCTest: true`,
/// writes under a throwaway service name that no shipping build ever uses, and
/// deletes what it wrote in teardown.
///
/// Enablement (either one; skips otherwise):
/// - `LV_KEYCHAIN_TEST_ENABLE=1` in the environment (direct runs on a Mac), or
/// - the gitignored marker `.keychain-integration-enable.json` at the repo
///   root, written by `./scripts/remote-build.sh integration-keychain` — the
///   SSH build gate allowlists exact `swift test ...` payloads, so enablement
///   has to travel inside the rsynced tree rather than as an env prefix.
///
/// It needs an unlocked login keychain in a real login session, which the SSH
/// build host does NOT have: reads work there, but `SecItemAdd` answers -60008
/// ("Unable to obtain authorization for this operation."), and a merely locked
/// keychain answers `errSecInteractionNotAllowed` (-25308). Either way this
/// suite FAILS saying so rather than skipping — a silent skip is exactly the
/// outcome that would let a broken keychain path ship. Run it from a terminal
/// in the owner's GUI session.
final class KeychainSecretStoreIntegrationTests: XCTestCase {
    private static let enableEnv = "LV_KEYCHAIN_TEST_ENABLE"
    private static let markerFileName = ".keychain-integration-enable.json"

    /// Unique per test run, so a crashed earlier run can never collide with
    /// this one and nothing here can touch the real `com.localvoxtral.api-keys`
    /// items on the build user's keychain.
    private var throwawayService = ""
    private var store: KeychainSecretStore!

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // localvoxtralTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        let enabledByEnv =
            ProcessInfo.processInfo.environment[Self.enableEnv]?.trimmed == "1"
        let markerURL = repoRoot.appendingPathComponent(Self.markerFileName)
        let enabledByMarker = FileManager.default.fileExists(atPath: markerURL.path)
        guard enabledByEnv || enabledByMarker else {
            throw XCTSkip(
                """
                Keychain integration tests are disabled.
                Enable with \(Self.enableEnv)=1 in the environment, or run
                ./scripts/remote-build.sh integration-keychain from the dev box
                (it writes the marker \(Self.markerFileName) into the synced tree).
                """
            )
        }

        throwawayService = "com.localvoxtral.api-keys.integration-test.\(UUID().uuidString)"
        store = KeychainSecretStore(service: throwawayService, allowUseUnderXCTest: true)
    }

    override func tearDownWithError() throws {
        if let store {
            for key in SecretKey.allCases {
                try? store.setSecret(nil, for: key)
            }
        }
        store = nil
        // Belt and braces: delete by service, so an item added under an
        // account this suite does not know about still goes away.
        if !throwawayService.isEmpty {
            _ = SecItemDelete(
                [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: throwawayService,
                ] as CFDictionary
            )
            throwawayService = ""
        }
        try super.tearDownWithError()
    }

    func testAddUpdateReadAndDeleteAgainstTheRealKeychain() throws {
        XCTAssertNil(try store.secret(for: .mistralAPIKey), "precondition: nothing stored yet")

        // Add
        try store.setSecret("mk-integration-one", for: .mistralAPIKey)
        XCTAssertEqual(try store.secret(for: .mistralAPIKey), "mk-integration-one")

        // Update (the SecItemUpdate branch, not a second SecItemAdd)
        try store.setSecret("mk-integration-two", for: .mistralAPIKey)
        XCTAssertEqual(try store.secret(for: .mistralAPIKey), "mk-integration-two")

        // A second instance reads the same item — the stand-in for a relaunch.
        let reader = KeychainSecretStore(service: throwawayService, allowUseUnderXCTest: true)
        XCTAssertEqual(try reader.secret(for: .mistralAPIKey), "mk-integration-two")

        // Delete
        try store.setSecret(nil, for: .mistralAPIKey)
        XCTAssertNil(try store.secret(for: .mistralAPIKey))
        XCTAssertNil(try reader.secret(for: .mistralAPIKey))

        // Deleting what is not there is not an error.
        XCTAssertNoThrow(try store.setSecret(nil, for: .mistralAPIKey))
    }

    func testEmptyStringDeletesAndKeysDoNotBleedIntoEachOther() throws {
        try store.setSecret("sk-realtime", for: .realtimeAPIKey)
        try store.setSecret("polish-key", for: .llmPolishingAPIKey)

        XCTAssertEqual(try store.secret(for: .realtimeAPIKey), "sk-realtime")
        XCTAssertEqual(try store.secret(for: .llmPolishingAPIKey), "polish-key")
        XCTAssertNil(try store.secret(for: .mistralAPIKey))

        try store.setSecret("", for: .realtimeAPIKey)
        XCTAssertNil(try store.secret(for: .realtimeAPIKey))
        XCTAssertEqual(
            try store.secret(for: .llmPolishingAPIKey), "polish-key",
            "deleting one account must not disturb its neighbours")
    }
}
