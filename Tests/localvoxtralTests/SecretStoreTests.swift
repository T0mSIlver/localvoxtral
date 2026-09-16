import Foundation
import Synchronization
import XCTest

@testable import localvoxtral

/// A secret store that can be told to refuse, standing in for a locked or
/// otherwise unhappy login keychain. `SecretStoring` is `Sendable`, so state
/// lives behind a `Mutex` like every other low-level type here.
final class FakeSecretStore: SecretStoring, @unchecked Sendable {
    /// `errSecInteractionNotAllowed` — what a locked keychain actually returns,
    /// so the fake fails the way the real thing does.
    static let interactionNotAllowed: Int32 = -25308

    private struct State {
        var values: [SecretKey: String] = [:]
        var readFailures: Set<SecretKey> = []
        var writeFailures: Set<SecretKey> = []
        var writtenKeys: [SecretKey] = []
    }

    private let state: Mutex<State>

    init(
        values: [SecretKey: String] = [:],
        readFailures: Set<SecretKey> = [],
        writeFailures: Set<SecretKey> = []
    ) {
        state = Mutex(
            State(values: values, readFailures: readFailures, writeFailures: writeFailures))
    }

    func secret(for key: SecretKey) throws -> String? {
        try state.withLock { state in
            guard !state.readFailures.contains(key) else {
                throw SecretStoreError(
                    operation: .read, key: key, status: Self.interactionNotAllowed,
                    message: "User interaction is not allowed.")
            }
            return state.values[key]
        }
    }

    func setSecret(_ value: String?, for key: SecretKey) throws {
        try state.withLock { state in
            guard !state.writeFailures.contains(key) else {
                throw SecretStoreError(
                    operation: .write, key: key, status: Self.interactionNotAllowed,
                    message: "User interaction is not allowed.")
            }
            state.writtenKeys.append(key)
            guard let value, !value.isEmpty else {
                state.values.removeValue(forKey: key)
                return
            }
            state.values[key] = value
        }
    }

    var snapshot: [SecretKey: String] { state.withLock { $0.values } }
    var writtenKeys: [SecretKey] { state.withLock { $0.writtenKeys } }
}

@MainActor
final class SecretStoreTests: XCTestCase {
    // The plist keys the three secrets used to live under. Spelled out here
    // rather than reached through `SettingsStore.Keys` (which is private, and
    // deliberately so) — these literals are what a user's existing
    // ~/Library/Preferences file contains.
    private static let legacyRealtimeKey = "settings.api_key"
    private static let legacyPolishingKey = "settings.llm_polishing_api_key"
    private static let legacyMistralKey = "settings.mistral_api_key"
    private static let migratedFlagKey = "settings.api_keys_migrated_to_keychain"

    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "localvoxtral.SecretStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
        try await super.tearDown()
    }

    private func makeStore(
        secretStore: any SecretStoring,
        environment: [String: String] = [:]
    ) -> SettingsStore {
        SettingsStore(defaults: defaults, environment: environment, secretStore: secretStore)
    }

    // MARK: - The account names are a wire format

    /// Renaming a case here orphans a user's stored key exactly the way
    /// renaming a defaults key would. Pinned so that is a deliberate act.
    func testSecretKeyAccountNamesAreStable() {
        XCTAssertEqual(
            SecretKey.allCases.map(\.rawValue),
            ["realtimeAPIKey", "llmPolishingAPIKey", "mistralAPIKey"]
        )
        XCTAssertEqual(KeychainSecretStore.defaultService, "com.localvoxtral.api-keys")
    }

    // MARK: - InMemorySecretStore

    func testInMemoryStoreRoundTripsAndTreatsEmptyAsDelete() throws {
        let store = InMemorySecretStore()
        XCTAssertNil(try store.secret(for: .mistralAPIKey))

        try store.setSecret("mk-one", for: .mistralAPIKey)
        XCTAssertEqual(try store.secret(for: .mistralAPIKey), "mk-one")

        try store.setSecret("mk-two", for: .mistralAPIKey)
        XCTAssertEqual(try store.secret(for: .mistralAPIKey), "mk-two")

        // Both spellings of "no secret" delete rather than store a blank, so a
        // cleared field can never leave a stale key behind.
        try store.setSecret("", for: .mistralAPIKey)
        XCTAssertNil(try store.secret(for: .mistralAPIKey))

        try store.setSecret("mk-three", for: .mistralAPIKey)
        try store.setSecret(nil, for: .mistralAPIKey)
        XCTAssertNil(try store.secret(for: .mistralAPIKey))

        // Keys do not bleed into each other.
        try store.setSecret("sk-realtime", for: .realtimeAPIKey)
        XCTAssertEqual(try store.secret(for: .realtimeAPIKey), "sk-realtime")
        XCTAssertNil(try store.secret(for: .llmPolishingAPIKey))
    }

    // MARK: - SettingsStore write-through

    func testAllThreeKeysWriteToTheSecretStoreAndNeverToUserDefaults() {
        let secrets = InMemorySecretStore()
        let store = makeStore(secretStore: secrets)

        store.apiKey = "  sk-realtime  "
        store.llmPolishingAPIKey = "polish-key"
        store.mistralAPIKey = "mk-mistral"

        XCTAssertEqual(
            secrets.snapshot,
            [
                .realtimeAPIKey: "sk-realtime",
                .llmPolishingAPIKey: "polish-key",
                .mistralAPIKey: "mk-mistral",
            ],
            "stored trimmed: a pasted key routinely carries a trailing newline"
        )
        for key in [Self.legacyRealtimeKey, Self.legacyPolishingKey, Self.legacyMistralKey] {
            XCTAssertNil(
                defaults.object(forKey: key),
                "\(key) must never be written again — that is the whole point of this change"
            )
        }
    }

    func testKeysComeBackFromTheSecretStoreOnTheNextLaunch() {
        let secrets = InMemorySecretStore()
        let first = makeStore(secretStore: secrets)
        first.apiKey = "sk-realtime"
        first.llmPolishingAPIKey = "polish-key"
        first.mistralAPIKey = "mk-mistral"

        let second = makeStore(secretStore: secrets)
        XCTAssertEqual(second.apiKey, "sk-realtime")
        XCTAssertEqual(second.llmPolishingAPIKey, "polish-key")
        XCTAssertEqual(second.mistralAPIKey, "mk-mistral")
    }

    func testClearingAKeyDeletesTheStoredItem() {
        let secrets = InMemorySecretStore()
        let store = makeStore(secretStore: secrets)
        store.mistralAPIKey = "mk-mistral"
        XCTAssertEqual(secrets.snapshot[.mistralAPIKey], "mk-mistral")

        store.mistralAPIKey = "   "
        XCTAssertNil(secrets.snapshot[.mistralAPIKey])
        XCTAssertEqual(makeStore(secretStore: secrets).mistralAPIKey, "")
    }

    // MARK: - One-time migration out of UserDefaults

    func testMigrationMovesEveryPlistKeyIntoTheSecretStoreAndRemovesIt() {
        defaults.set("  sk-realtime  ", forKey: Self.legacyRealtimeKey)
        defaults.set("polish-key", forKey: Self.legacyPolishingKey)
        defaults.set("mk-mistral", forKey: Self.legacyMistralKey)

        let secrets = InMemorySecretStore()
        let store = makeStore(secretStore: secrets)

        XCTAssertEqual(
            secrets.snapshot,
            [
                .realtimeAPIKey: "sk-realtime",
                .llmPolishingAPIKey: "polish-key",
                .mistralAPIKey: "mk-mistral",
            ]
        )
        XCTAssertEqual(store.apiKey, "sk-realtime")
        XCTAssertEqual(store.llmPolishingAPIKey, "polish-key")
        XCTAssertEqual(store.mistralAPIKey, "mk-mistral")

        for key in [Self.legacyRealtimeKey, Self.legacyPolishingKey, Self.legacyMistralKey] {
            XCTAssertNil(defaults.object(forKey: key), "the plist copy of \(key) must be gone")
        }
        XCTAssertTrue(defaults.bool(forKey: Self.migratedFlagKey))
        XCTAssertNil(store.secretStoreFailureSummary)
    }

    /// A downgrade-then-upgrade leaves a stale plist copy beside a newer
    /// keychain item. The newer one wins; the plist copy is simply removed.
    func testMigrationNeverOverwritesAValueTheSecretStoreAlreadyHolds() {
        defaults.set("mk-stale-from-the-plist", forKey: Self.legacyMistralKey)
        let secrets = InMemorySecretStore([.mistralAPIKey: "mk-current"])

        let store = makeStore(secretStore: secrets)

        XCTAssertEqual(secrets.snapshot[.mistralAPIKey], "mk-current")
        XCTAssertEqual(store.mistralAPIKey, "mk-current")
        XCTAssertNil(defaults.object(forKey: Self.legacyMistralKey))
    }

    /// Losing a user's API key is worse than leaving a copy of it where it
    /// already was: a refused write keeps the plist value AND keeps using it.
    func testMigrationKeepsThePlistValueWhenTheKeychainWriteFails() {
        defaults.set("mk-mistral", forKey: Self.legacyMistralKey)
        defaults.set("sk-realtime", forKey: Self.legacyRealtimeKey)
        let secrets = FakeSecretStore(writeFailures: [.mistralAPIKey])

        let store = makeStore(secretStore: secrets)

        XCTAssertEqual(
            defaults.string(forKey: Self.legacyMistralKey), "mk-mistral",
            "the only copy of the key must survive a refused write")
        XCTAssertEqual(store.mistralAPIKey, "mk-mistral", "and still work for this launch")
        XCTAssertFalse(
            defaults.bool(forKey: Self.migratedFlagKey),
            "an incomplete sweep must run again on the next launch")
        XCTAssertEqual(
            store.secretStoreFailureSummary, SettingsStore.secretStoreWriteFailureSummary)

        // The keys that DID migrate are still cleaned up.
        XCTAssertNil(defaults.object(forKey: Self.legacyRealtimeKey))
        XCTAssertEqual(secrets.snapshot[.realtimeAPIKey], "sk-realtime")
    }

    /// The probe that protects a newer keychain value is itself a keychain
    /// call. If it refuses, writing blind could clobber a good key — so the
    /// migration leaves everything alone.
    func testMigrationLeavesThePlistValueAloneWhenTheProbeReadFails() {
        defaults.set("mk-mistral", forKey: Self.legacyMistralKey)
        let secrets = FakeSecretStore(readFailures: [.mistralAPIKey])

        let store = makeStore(secretStore: secrets)

        XCTAssertEqual(defaults.string(forKey: Self.legacyMistralKey), "mk-mistral")
        XCTAssertEqual(store.mistralAPIKey, "mk-mistral")
        XCTAssertTrue(secrets.writtenKeys.isEmpty, "nothing may be written on a blind probe")
        XCTAssertFalse(defaults.bool(forKey: Self.migratedFlagKey))
    }

    func testAMigratedInstallNeverReadsThePlistAgain() {
        defaults.set(true, forKey: Self.migratedFlagKey)
        // Whatever put this here, it is not a source of truth any more.
        defaults.set("mk-should-be-ignored", forKey: Self.legacyMistralKey)

        let store = makeStore(secretStore: InMemorySecretStore())

        XCTAssertEqual(store.mistralAPIKey, "")
        XCTAssertEqual(
            defaults.string(forKey: Self.legacyMistralKey), "mk-should-be-ignored",
            "not read, and not rewritten either: erasing a stranger's key is not our business")
    }

    func testAFreshInstallMarksItselfMigratedWithoutWritingAnything() {
        let secrets = InMemorySecretStore()
        _ = makeStore(secretStore: secrets)

        XCTAssertTrue(defaults.bool(forKey: Self.migratedFlagKey))
        XCTAssertTrue(secrets.snapshot.isEmpty)
    }

    // MARK: - A keychain that will not answer

    func testAReadFailureReportsItselfInsteadOfClaimingTheKeyIsMissing() {
        defaults.set(true, forKey: Self.migratedFlagKey)
        let secrets = FakeSecretStore(
            values: [.mistralAPIKey: "mk-mistral"],
            readFailures: Set(SecretKey.allCases)
        )

        let store = makeStore(secretStore: secrets)

        XCTAssertEqual(store.apiKey, "")
        XCTAssertEqual(store.llmPolishingAPIKey, "")
        XCTAssertEqual(store.mistralAPIKey, "")
        XCTAssertEqual(
            store.secretStoreFailureSummary, SettingsStore.secretStoreReadFailureSummary)
        XCTAssertEqual(
            store.mistralAPIStatusSummary, SettingsStore.secretStoreReadFailureSummary,
            "a locked keychain must not send the user hunting for a key they already pasted"
        )
    }

    func testAWriteFailureAfterLaunchSurfacesInTheEngineStatus() {
        defaults.set(true, forKey: Self.migratedFlagKey)
        let secrets = FakeSecretStore(writeFailures: [.mistralAPIKey])
        let store = makeStore(secretStore: secrets)
        XCTAssertNil(store.secretStoreFailureSummary)

        store.mistralAPIKey = "mk-mistral"

        XCTAssertEqual(
            store.secretStoreFailureSummary, SettingsStore.secretStoreWriteFailureSummary)
        XCTAssertEqual(
            store.mistralAPIStatusSummary, SettingsStore.secretStoreWriteFailureSummary,
            "the key works this session but is not saved — 'Ready' would be a lie"
        )
    }

    func testAHealthyStoreShowsTheOrdinaryMistralStatus() {
        let store = makeStore(secretStore: InMemorySecretStore())
        XCTAssertEqual(store.mistralAPIStatusSummary, "API key missing")
        store.mistralAPIKey = "mk-mistral"
        XCTAssertEqual(store.mistralAPIStatusSummary, "Ready")
        XCTAssertNil(store.secretStoreFailureSummary)
    }

    // MARK: - Environment overrides (unchanged by the move)

    func testEnvironmentOverridesStillApplyAndAreNeverPersisted() {
        let secrets = InMemorySecretStore()
        let store = makeStore(
            secretStore: secrets,
            environment: [
                "OPENAI_API_KEY": "sk-from-env",
                "LLM_POLISHING_API_KEY": "polish-from-env",
                "MISTRAL_API_KEY": "mk-from-env",
            ]
        )

        XCTAssertEqual(store.apiKey, "sk-from-env")
        XCTAssertEqual(store.llmPolishingAPIKey, "polish-from-env")
        XCTAssertEqual(store.mistralAPIKey, "mk-from-env")
        XCTAssertTrue(
            secrets.snapshot.isEmpty,
            "an env key belongs to the process that exported it, not to the user's keychain")
        XCTAssertNil(defaults.object(forKey: Self.legacyMistralKey))
    }

    func testAStoredKeyBeatsAnEnvironmentOverride() {
        let secrets = InMemorySecretStore([.mistralAPIKey: "mk-stored"])
        let store = makeStore(
            secretStore: secrets, environment: ["MISTRAL_API_KEY": "mk-from-env"])

        XCTAssertEqual(store.mistralAPIKey, "mk-stored")
    }
}
