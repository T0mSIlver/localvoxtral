import Foundation
import Synchronization
import XCTest

@testable import localvoxtral

/// A secret store that records what was asked of it, so a test can prove the
/// app did not touch the keychain at all.
final class CountingSecretStore: SecretStoring, @unchecked Sendable {
    /// `errSecInteractionNotAllowed` — what a locked keychain returns.
    static let interactionNotAllowed: Int32 = -25308

    private struct State {
        var values: [SecretKey: String]
        var readFailures: Set<SecretKey>
        var reads: [SecretKey] = []
        var writes: [SecretKey] = []
    }

    private let state: Mutex<State>

    init(_ values: [SecretKey: String] = [:], readFailures: Set<SecretKey> = []) {
        state = Mutex(State(values: values, readFailures: readFailures))
    }

    func secret(for key: SecretKey) throws -> String? {
        try state.withLock { state in
            state.reads.append(key)
            guard !state.readFailures.contains(key) else {
                throw SecretStoreError(
                    operation: .read, key: key, status: Self.interactionNotAllowed,
                    message: "User interaction is not allowed.")
            }
            return state.values[key]
        }
    }

    func setSecret(_ value: String?, for key: SecretKey) throws {
        state.withLock { state in
            state.writes.append(key)
            guard let value, !value.isEmpty else {
                state.values.removeValue(forKey: key)
                return
            }
            state.values[key] = value
        }
    }

    var reads: [SecretKey] { state.withLock { $0.reads } }
    var writes: [SecretKey] { state.withLock { $0.writes } }
}

/// Every keychain read can cost the user a modal prompt: the app has no Team
/// ID, so macOS partitions its items by the build's code-signing hash and the
/// first read from a newly installed build never matches. These tests pin who
/// reads what, and when.
@MainActor
final class LazySecretLoadingTests: XCTestCase {
    private static let migratedFlagKey = "settings.api_keys_migrated_to_keychain"
    private static let dictationModeKey = "settings.dictation_backend_mode"
    private static let polishingModeKey = "settings.polishing_backend_mode"
    private static let polishingEnabledKey = "settings.llm_polishing_enabled"

    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "localvoxtral.LazySecretLoadingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        // Every case here is an install that has already migrated: the sweep
        // out of UserDefaults is a separate contract (SecretStoreTests).
        defaults.set(true, forKey: Self.migratedFlagKey)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
        try await super.tearDown()
    }

    private func makeStore(
        _ secrets: CountingSecretStore,
        environment: [String: String] = [:]
    ) -> SettingsStore {
        SettingsStore(defaults: defaults, environment: environment, secretStore: secrets)
    }

    // MARK: - Launch

    /// The default install dictates through the bundled helper and polishes
    /// locally. Nothing there authenticates with anything, so launch must not
    /// open the keychain — this is the case that stops a prompt from landing on
    /// a user who never configured a hosted engine.
    func testAManagedLocalLaunchReadsNoSecret() {
        let secrets = CountingSecretStore([
            .realtimeAPIKey: "sk-realtime",
            .llmPolishingAPIKey: "polish-key",
            .mistralAPIKey: "mk-mistral",
        ])
        defaults.set(BackendMode.managedLocal.rawValue, forKey: Self.dictationModeKey)
        defaults.set(BackendMode.managedLocal.rawValue, forKey: Self.polishingModeKey)
        defaults.set(true, forKey: Self.polishingEnabledKey)

        let store = makeStore(secrets)

        XCTAssertEqual(secrets.reads, [], "a local-only setup has no key to read")
        XCTAssertEqual(store.trimmedAPIKey, "")
    }

    /// The other half of the contract: a hosted engine selected at launch gets
    /// its key up front, because the session path reads it without asking.
    func testALaunchWithAHostedEngineLoadsExactlyThatEnginesKey() {
        let secrets = CountingSecretStore([
            .realtimeAPIKey: "sk-realtime",
            .llmPolishingAPIKey: "polish-key",
            .mistralAPIKey: "mk-mistral",
        ])
        defaults.set(BackendMode.mistralAPI.rawValue, forKey: Self.dictationModeKey)
        defaults.set(BackendMode.managedLocal.rawValue, forKey: Self.polishingModeKey)

        let store = makeStore(secrets)

        XCTAssertEqual(secrets.reads, [.mistralAPIKey])
        XCTAssertEqual(store.trimmedAPIKey, "mk-mistral", "the session path needs it at launch")
        XCTAssertEqual(store.apiKey, "", "the External URL key belongs to an engine nobody picked")
    }

    /// A polishing server needs its bearer token only while polishing is on.
    func testTheDisabledPolishingEngineKeyIsNotRead() {
        let secrets = CountingSecretStore([.llmPolishingAPIKey: "polish-key"])
        defaults.set(BackendMode.externalURL.rawValue, forKey: Self.polishingModeKey)
        defaults.set(false, forKey: Self.polishingEnabledKey)

        let store = makeStore(secrets)
        XCTAssertEqual(secrets.reads, [])

        store.llmPolishingEnabled = true
        XCTAssertEqual(secrets.reads, [.llmPolishingAPIKey])
        XCTAssertEqual(store.llmPolishingAPIKey, "polish-key")
    }

    // MARK: - Switching engines

    func testSwitchingToAHostedEngineLoadsItsKeyThen() {
        let secrets = CountingSecretStore([.mistralAPIKey: "mk-mistral"])
        let store = makeStore(secrets)
        XCTAssertEqual(secrets.reads, [])

        store.dictationBackendMode = .mistralAPI

        XCTAssertEqual(secrets.reads, [.mistralAPIKey])
        XCTAssertEqual(store.trimmedMistralAPIKey, "mk-mistral")
    }

    func testOpeningSettingsLoadsEveryKeyOnce() {
        let secrets = CountingSecretStore([
            .realtimeAPIKey: "sk-realtime",
            .llmPolishingAPIKey: "polish-key",
            .mistralAPIKey: "mk-mistral",
        ])
        let store = makeStore(secrets)

        // What SettingsView.onAppear calls: the panes show all three fields.
        store.ensureAllSecretsLoaded()
        XCTAssertEqual(Set(secrets.reads), Set(SecretKey.allCases))
        XCTAssertEqual(store.apiKey, "sk-realtime")
        XCTAssertEqual(store.llmPolishingAPIKey, "polish-key")
        XCTAssertEqual(store.mistralAPIKey, "mk-mistral")

        // Re-opening Settings, switching engines, exporting diagnostics: one
        // read per key per process is the budget, because each one is a prompt.
        store.ensureAllSecretsLoaded()
        store.dictationBackendMode = .mistralAPI
        XCTAssertEqual(secrets.reads.count, SecretKey.allCases.count)
    }

    /// A value that just came OUT of the store must not go back IN: a write
    /// raises the same dialog a read does.
    func testALoadedSecretIsNeverWrittenBack() {
        let secrets = CountingSecretStore([
            .realtimeAPIKey: "sk-realtime",
            .llmPolishingAPIKey: "polish-key",
            .mistralAPIKey: "mk-mistral",
        ])
        let store = makeStore(secrets)

        store.ensureAllSecretsLoaded()

        XCTAssertEqual(secrets.writes, [])
    }

    /// A key the user types is stored, and the store already holds it — so
    /// nothing later needs to read it back.
    func testAKeyTypedByTheUserIsNotReadBackAfterwards() {
        let secrets = CountingSecretStore()
        let store = makeStore(secrets)

        store.mistralAPIKey = "mk-typed"
        store.ensureAllSecretsLoaded()

        XCTAssertEqual(secrets.writes, [.mistralAPIKey])
        XCTAssertFalse(secrets.reads.contains(.mistralAPIKey))
        XCTAssertEqual(store.mistralAPIKey, "mk-typed")
    }

    /// A refused read is not retried: the user answered the dialog once (or the
    /// keychain is locked), and asking again on every engine switch is exactly
    /// the storm this change exists to stop.
    func testARefusedReadIsNotRetried() {
        let secrets = CountingSecretStore(
            [.mistralAPIKey: "mk-mistral"], readFailures: [.mistralAPIKey])
        let store = makeStore(secrets)

        store.dictationBackendMode = .mistralAPI
        XCTAssertEqual(secrets.reads, [.mistralAPIKey])
        XCTAssertEqual(
            store.secretStoreFailureSummary, SettingsStore.secretStoreReadFailureSummary,
            "and it says so, instead of reading as an unset key")

        store.ensureAllSecretsLoaded()
        store.dictationBackendMode = .managedLocal
        store.dictationBackendMode = .mistralAPI

        XCTAssertEqual(
            secrets.reads.filter { $0 == .mistralAPIKey }, [.mistralAPIKey],
            "one refused read, not one per engine switch")
        XCTAssertEqual(store.mistralAPIKey, "")
    }

    // MARK: - Which engine needs which key

    func testSecretsInUsePerEngineCombination() {
        func secrets(
            _ dictation: BackendMode, _ polishing: BackendMode, _ polishingEnabled: Bool = true
        ) -> Set<SecretKey> {
            SettingsStore.secretsInUse(
                dictationMode: dictation, polishingMode: polishing,
                polishingEnabled: polishingEnabled)
        }

        XCTAssertEqual(secrets(.managedLocal, .managedLocal), [])
        XCTAssertEqual(secrets(.externalURL, .managedLocal), [.realtimeAPIKey])
        XCTAssertEqual(secrets(.managedLocal, .externalURL), [.llmPolishingAPIKey])
        XCTAssertEqual(secrets(.mistralAPI, .managedLocal), [.mistralAPIKey])
        XCTAssertEqual(secrets(.managedLocal, .mistralAPI), [.mistralAPIKey])
        XCTAssertEqual(
            secrets(.mistralAPI, .mistralAPI), [.mistralAPIKey],
            "one Mistral account key, shared by both engines")
        XCTAssertEqual(
            secrets(.externalURL, .externalURL), [.realtimeAPIKey, .llmPolishingAPIKey])
        XCTAssertEqual(
            secrets(.externalURL, .mistralAPI, false), [.realtimeAPIKey],
            "polishing off means its key is nobody's business")
    }

    // MARK: - The CI opt-out

    /// CI packages and launches the real app on the owner's Mac on every push.
    /// A build it just made has a code-signing hash no keychain item's ACL
    /// knows, so the read pops a dialog on his desktop — once per run, which is
    /// every keychain prompt his Mac saw on 2026-09-17. These lanes get a
    /// process-local store instead.
    func testTheCILaunchFlagsKeepTheAppOutOfTheLoginKeychain() {
        for key in [
            StartupPermissionSuppression.environmentKey,
            StartupPermissionSuppression.keychainEnvironmentKey,
        ] {
            let store = DefaultSecretStore.make(environment: [key: "1"])
            XCTAssertTrue(
                store is InMemorySecretStore,
                "\(key)=1 must not reach the login keychain")

            // No `secretStore:` argument: this is the production path, and
            // before the fix it built a KeychainSecretStore (which traps under
            // XCTest precisely so this cannot go unnoticed).
            let settings = SettingsStore(defaults: defaults, environment: [key: "1"])
            settings.ensureAllSecretsLoaded()
            XCTAssertEqual(settings.mistralAPIKey, "")
        }

        XCTAssertFalse(
            StartupPermissionSuppression.loginKeychainIsDisabled(environment: [:]),
            "an ordinary launch reads the user's keys")
        XCTAssertTrue(
            StartupPermissionSuppression.loginKeychainIsDisabled(
                environment: [StartupPermissionSuppression.environmentKey: "1"]),
            "suppressing the startup prompts implies suppressing the keychain one")
    }

    /// A lane that only needs the keychain silenced must keep the production
    /// startup permission pass.
    func testTheKeychainFlagAloneDoesNotSuppressTheStartupPermissionPass() {
        XCTAssertFalse(
            DictationViewModel.startupPermissionPromptsSuppressed(
                environment: [StartupPermissionSuppression.keychainEnvironmentKey: "1"]))
        XCTAssertTrue(
            DictationViewModel.startupPermissionPromptsSuppressed(
                environment: [StartupPermissionSuppression.environmentKey: "1"]))
    }
}
