import Foundation
import Synchronization
import XCTest

@testable import localvoxtral

/// The Mistral API mode's view-model wiring: which realtime client a session
/// speaks to, what a mode switch does to the managed engines, and the quick
/// setup / key-check seams the Engines pane and the wizard both drive.
@MainActor
final class MistralAPIModeTests: XCTestCase {
    // MARK: - Active realtime client

    func testActiveRealtimeClientDefaultsToTheOpenAICompatibleClient() {
        let (viewModel, _, _) = makeViewModel()

        XCTAssertTrue(viewModel.activeRealtimeClient === viewModel.realtimeAPIClient)
    }

    func testRealtimeClientForModeSelectsTheMistralTransportOnlyForMistralMode() {
        let (viewModel, _, _) = makeViewModel()

        XCTAssertTrue(
            viewModel.realtimeClient(for: .mistralAPI) === viewModel.mistralRealtimeClient
        )
        XCTAssertTrue(
            viewModel.realtimeClient(for: .externalURL) === viewModel.realtimeAPIClient
        )
        XCTAssertTrue(
            viewModel.realtimeClient(for: .managedLocal) === viewModel.realtimeAPIClient
        )
    }

    func testLatchFollowsTheConfiguredModeWhileIdle() {
        let (viewModel, settings, _) = makeViewModel()

        settings.dictationBackendMode = .mistralAPI
        viewModel.latchActiveRealtimeClient()
        XCTAssertTrue(viewModel.activeRealtimeClient === viewModel.mistralRealtimeClient)

        settings.dictationBackendMode = .externalURL
        viewModel.latchActiveRealtimeClient()
        XCTAssertTrue(viewModel.activeRealtimeClient === viewModel.realtimeAPIClient)
    }

    func testAModeChangeMidSessionDoesNotSwapTheClientUnderTheLiveSession() {
        let (viewModel, settings, _) = makeViewModel()
        settings.dictationBackendMode = .mistralAPI
        viewModel.latchActiveRealtimeClient()
        XCTAssertTrue(viewModel.activeRealtimeClient === viewModel.mistralRealtimeClient)

        // Settings changed while the session runs: the latch is what keeps the
        // session's audio, its stop, and its disconnect on one client.
        viewModel.applyDictationBackendModeChange(.externalURL)

        XCTAssertTrue(
            viewModel.activeRealtimeClient === viewModel.mistralRealtimeClient,
            "the running session keeps the client it latched at start"
        )

        // The NEXT session picks up the new mode.
        viewModel.latchActiveRealtimeClient()
        XCTAssertTrue(viewModel.activeRealtimeClient === viewModel.realtimeAPIClient)
    }

    func testMistralTransportAdvertisesNoPeriodicCommit() {
        let (viewModel, _, _) = makeViewModel()

        // `restartCommitTask` keys off this, so a Mistral session gets no
        // periodic commit task — the wire has no partial commit.
        XCTAssertFalse(viewModel.mistralRealtimeClient.supportsPeriodicCommit)
        XCTAssertTrue(viewModel.realtimeAPIClient.supportsPeriodicCommit)
    }

    // MARK: - Mode changes and the managed engines

    func testSwitchingDictationFromManagedToMistralStopsTheManagedEngine() async {
        let (viewModel, settings, backendManager) = makeViewModel()
        settings.dictationBackendMode = .managedLocal

        viewModel.applyDictationBackendModeChange(.mistralAPI)
        await Self.awaitBackendLifecycle(viewModel)

        XCTAssertEqual(settings.dictationBackendMode, .mistralAPI)
        XCTAssertEqual(backendManager.stopDictationCallCount, 1)
        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
    }

    func testSwitchingPolishingFromManagedToMistralStopsTheManagedEngine() async {
        let (viewModel, settings, backendManager) = makeViewModel()
        settings.polishingBackendMode = .managedLocal

        viewModel.applyPolishingBackendModeChange(.mistralAPI)
        await Self.awaitBackendLifecycle(viewModel)

        XCTAssertEqual(settings.polishingBackendMode, .mistralAPI)
        XCTAssertEqual(backendManager.stopPolishingCallCount, 1)
        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
    }

    func testSwitchingBetweenExternalAndMistralNeverTouchesTheManagedEngines() async {
        let (viewModel, settings, backendManager) = makeViewModel()
        settings.dictationBackendMode = .externalURL
        settings.polishingBackendMode = .externalURL

        viewModel.applyDictationBackendModeChange(.mistralAPI)
        viewModel.applyPolishingBackendModeChange(.mistralAPI)
        viewModel.applyDictationBackendModeChange(.externalURL)
        viewModel.applyPolishingBackendModeChange(.externalURL)
        await Self.awaitBackendLifecycle(viewModel)

        XCTAssertEqual(backendManager.stopDictationCallCount, 0)
        XCTAssertEqual(backendManager.stopPolishingCallCount, 0)
        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
    }

    func testSwitchingBackFromMistralToManagedWarmsTheEngineUp() async {
        let (viewModel, settings, backendManager) = makeViewModel()
        settings.onboardingCompleted = true
        settings.dictationBackendMode = .mistralAPI

        viewModel.applyDictationBackendModeChange(.managedLocal)
        await Self.awaitBackendLifecycle(viewModel)

        XCTAssertEqual(
            backendManager.ensureCalls,
            [OnboardingTestBackendManager.EnsureCall(dictation: true, polishing: false)]
        )
    }

    func testMistralModeRequestsNoLocalNetworkPreflight() {
        let preflight = RecordingPreflight()
        let (viewModel, settings, _) = makeViewModel(preflight: preflight)
        settings.dictationBackendMode = .managedLocal
        settings.polishingBackendMode = .managedLocal

        viewModel.applyDictationBackendModeChange(.mistralAPI)
        viewModel.applyPolishingBackendModeChange(.mistralAPI)
        viewModel.preflightConfiguredLocalNetworkEndpoints()

        // api.mistral.ai is not on the local network, so asking macOS for the
        // local-network permission would be a prompt with nothing behind it.
        XCTAssertTrue(preflight.requests.isEmpty)
        XCTAssertNil(
            LocalNetworkEndpointPolicy.preflightTarget(
                for: MistralRealtimeWebSocketClient.defaultEndpoint
            )
        )
    }

    // MARK: - Managed polishing gates

    func testMistralPolishingIsNeverManagedAndNeverWarmedUp() {
        let (viewModel, settings, _) = makeViewModel()
        settings.llmPolishingEnabled = true
        settings.modifierOnlyHotKeyEnabled = true
        settings.polishingBackendMode = .mistralAPI

        XCTAssertFalse(viewModel.isManagedPolishingRequired(outputMode: .overlayBuffer))
        XCTAssertFalse(viewModel.isManagedPolishingWarmupWanted)

        // Same answer External URL gets, which is the point.
        settings.polishingBackendMode = .externalURL
        XCTAssertFalse(viewModel.isManagedPolishingRequired(outputMode: .overlayBuffer))
        XCTAssertFalse(viewModel.isManagedPolishingWarmupWanted)
    }

    func testPolishPromptWarmupPlansNothingForMistralMode() {
        let (_, settings, _) = makeViewModel()
        settings.llmPolishingEnabled = true
        settings.polishingBackendMode = .mistralAPI
        settings.mistralAPIKey = "mk-mistral"

        // Warming someone else's server is never our business — and a hosted
        // request would be billed for nothing.
        XCTAssertNotNil(settings.llmPolishingConfiguration, "precondition: config resolves")
        XCTAssertNil(
            PolishPromptWarmup.plan(settings: settings, appConfigStore: MockAppConfigStore())
        )
    }

    // MARK: - Quick setup

    func testQuickSetupStoresTheKeySwitchesBothEnginesAndEnablesPolishing() async {
        let (viewModel, settings, backendManager) = makeViewModel()
        settings.dictationBackendMode = .managedLocal
        settings.polishingBackendMode = .managedLocal
        XCTAssertFalse(settings.llmPolishingEnabled)

        viewModel.applyMistralQuickSetup(apiKey: "  mk-mistral  ")
        await Self.awaitBackendLifecycle(viewModel)

        XCTAssertEqual(settings.mistralAPIKey, "mk-mistral")
        XCTAssertEqual(settings.dictationBackendMode, .mistralAPI)
        XCTAssertEqual(settings.polishingBackendMode, .mistralAPI)
        XCTAssertTrue(settings.llmPolishingEnabled)
        // Both managed engines stop; nothing is warmed up for a hosted mode.
        XCTAssertEqual(backendManager.stopDictationCallCount, 1)
        XCTAssertEqual(backendManager.stopPolishingCallCount, 1)
        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
    }

    func testQuickSetupProducesAUsablePolishingConfiguration() {
        let (viewModel, settings, _) = makeViewModel()

        viewModel.applyMistralQuickSetup(apiKey: "mk-mistral")

        let configuration = settings.llmPolishingConfiguration
        XCTAssertEqual(configuration?.endpointURL, MistralPolishDefaults.endpoint)
        XCTAssertEqual(configuration?.apiKey, "mk-mistral")
        XCTAssertEqual(configuration?.requestShape, .mistral)
        XCTAssertEqual(
            settings.resolvedWebSocketURL,
            MistralRealtimeWebSocketClient.defaultEndpoint
        )
        XCTAssertEqual(settings.trimmedAPIKey, "mk-mistral")
    }

    // MARK: - Key verification

    func testCheckKeyReportsAcceptance() async {
        let (viewModel, settings, _) = makeViewModel()
        let verifier = FakeMistralAPIKeyVerifier(result: .accepted)
        viewModel.mistralAPIKeyVerifier = verifier
        settings.mistralAPIKey = "mk-mistral"

        let verification = await viewModel.verifyMistralAPIKey(settings.mistralAPIKey)

        XCTAssertEqual(verification, .accepted)
        XCTAssertEqual(verifier.checkedKeys, ["mk-mistral"])
        XCTAssertEqual(MistralAPIKeyCheckState.finished(.accepted).statusLine, "Key accepted")
    }

    func testCheckKeyButtonDrivesTheEnginesPaneState() async {
        let (viewModel, settings, _) = makeViewModel()
        viewModel.mistralAPIKeyVerifier = FakeMistralAPIKeyVerifier(
            result: .rejected(statusCode: 401)
        )
        settings.mistralAPIKey = "mk-wrong"
        XCTAssertNil(viewModel.mistralAPIKeyCheckState.statusLine)

        viewModel.checkMistralAPIKey()
        XCTAssertEqual(viewModel.mistralAPIKeyCheckState, .checking)
        await viewModel.mistralAPIKeyCheckTask?.value

        XCTAssertEqual(
            viewModel.mistralAPIKeyCheckState, .finished(.rejected(statusCode: 401))
        )
        XCTAssertEqual(viewModel.mistralAPIKeyCheckState.statusLine, "Rejected (HTTP 401)")
    }

    func testCheckKeyStateLinesStayOneLine() {
        XCTAssertNil(MistralAPIKeyCheckState.idle.statusLine)
        XCTAssertEqual(MistralAPIKeyCheckState.checking.statusLine, "Checking…")
        XCTAssertEqual(
            MistralAPIKeyCheckState.finished(.rejected(statusCode: 401)).statusLine,
            "Rejected (HTTP 401)"
        )
        // The system's error text can be a paragraph; the row must not grow one.
        XCTAssertEqual(
            MistralAPIKeyCheckState.finished(
                .unreachable("A very long multi-line\nsystem failure description")
            ).statusLine,
            "Could not reach Mistral"
        )
    }

    func testVerifierStatusMappingNeverCallsAGoodKeyBad() {
        XCTAssertEqual(MistralAPIKeyVerifier.verification(forStatusCode: 200), .accepted)
        XCTAssertEqual(
            MistralAPIKeyVerifier.verification(forStatusCode: 401),
            .rejected(statusCode: 401)
        )
        XCTAssertEqual(
            MistralAPIKeyVerifier.verification(forStatusCode: 403),
            .rejected(statusCode: 403)
        )
        // Throttling and Mistral-side failures say nothing about the key.
        guard case .unreachable = MistralAPIKeyVerifier.verification(forStatusCode: 429) else {
            return XCTFail("429 must not be reported as a rejected key")
        }
        guard case .unreachable = MistralAPIKeyVerifier.verification(forStatusCode: 503) else {
            return XCTFail("a 5xx must not be reported as a rejected key")
        }
    }

    func testVerifyingAnEmptyKeyNeverOpensASocket() async {
        let verification = await MistralAPIKeyVerifier().verify(apiKey: "   ")

        XCTAssertEqual(verification, .unreachable("Enter an API key first."))
    }

    // MARK: - Model list

    func testModelListLoadsOncePerKeyIntoSettings() async {
        let (viewModel, settings, _) = makeViewModel()
        let glm = MistralModel(
            id: "zai-glm-5-3", ids: ["zai-glm-5-3", "zai-glm-latest"], supportsChat: true,
            supportsRealtimeTranscription: false, supportsReasoning: true, isDeprecated: false
        )
        let lister = FakeMistralModelLister(result: .loaded([glm]))
        viewModel.mistralModelLister = lister
        settings.mistralAPIKey = " mk-mistral "

        viewModel.refreshMistralModelCatalog()
        XCTAssertEqual(viewModel.mistralModelListState, .loading)
        XCTAssertEqual(viewModel.mistralModelListState.statusLine, "Loading models…")
        await viewModel.mistralModelListTask?.value

        XCTAssertEqual(settings.mistralModelCatalog, [glm])
        XCTAssertEqual(viewModel.mistralModelListState, .loaded)
        XCTAssertNil(viewModel.mistralModelListState.statusLine)
        XCTAssertEqual(lister.requestedKeys, ["mk-mistral"])

        // Reopening the pane with the same key costs no request.
        viewModel.refreshMistralModelCatalog()
        await viewModel.mistralModelListTask?.value
        XCTAssertEqual(lister.requestedKeys, ["mk-mistral"])
    }

    /// A failed fetch says so in one line and keeps the list it had: the
    /// pickers must not empty out because Wi-Fi dropped.
    func testAFailedModelListKeepsTheCachedList() async {
        let (viewModel, settings, _) = makeViewModel()
        let cached = MistralModel(
            id: "mistral-small-2603", ids: ["mistral-small-2603"], supportsChat: true,
            supportsRealtimeTranscription: false, supportsReasoning: true, isDeprecated: false
        )
        settings.mistralModelCatalog = [cached]
        settings.mistralAPIKey = "mk-wrong"
        viewModel.mistralModelLister = FakeMistralModelLister(result: .rejected(statusCode: 401))

        viewModel.refreshMistralModelCatalog()
        await viewModel.mistralModelListTask?.value

        XCTAssertEqual(settings.mistralModelCatalog, [cached])
        XCTAssertEqual(viewModel.mistralModelListState.statusLine, "Key rejected")
        XCTAssertEqual(
            MistralModelListState.failed(.failed("A long\nsystem error")).statusLine,
            "Could not load models"
        )
    }

    func testModelListWithoutAKeyNeverAsks() async {
        let (viewModel, _, _) = makeViewModel()
        let lister = FakeMistralModelLister(result: .loaded([]))
        viewModel.mistralModelLister = lister

        viewModel.refreshMistralModelCatalog()

        XCTAssertNil(viewModel.mistralModelListTask)
        XCTAssertEqual(lister.requestedKeys, [])
        XCTAssertEqual(viewModel.mistralModelListState, .idle)
    }

    // MARK: - Usage ledger

    /// Both Mistral request paths write the ledger Settings reads: the
    /// realtime socket the view model owns, and the polishing service it
    /// calls. A path left unwired would under-report without any error.
    func testInstalledUsageLedgerReceivesBothMistralPaths() async throws {
        let (viewModel, _, _) = makeViewModel()
        XCTAssertNil(viewModel.mistralUsageLedger, "tests never write the user's ledger")
        let ledger = MistralUsageLedger(fileURL: nil)
        viewModel.installMistralUsageLedger(ledger)
        XCTAssertTrue(viewModel.mistralUsageLedger === ledger)

        #if DEBUG
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:65535/test")!)
        defer {
            task.cancel()
            session.invalidateAndCancel()
        }
        viewModel.mistralRealtimeClient.debugPrimeConnectedStateForTesting(
            task: task, isUserInitiatedDisconnect: true, hasReceivedSessionCreated: true,
            usageModel: MistralRealtimeWebSocketClient.defaultModel)
        viewModel.mistralRealtimeClient.sendAudioChunk(Data(count: 16_000))
        viewModel.mistralRealtimeClient.disconnect()
        XCTAssertEqual(ledger.entries().map(\.audioSeconds), [0.5])
        #endif

        let service = try XCTUnwrap(viewModel.llmPolishingService as? LLMPolishingService)
        XCTAssertTrue((service.usageRecorder as? MistralUsageLedger) === ledger)
    }

    // MARK: - Fixtures

    /// Drain the backend-lifecycle tasks a mode change starts. No polling and
    /// no wall-clock: the tasks are kept awaitable exactly for this.
    private static func awaitBackendLifecycle(_ viewModel: DictationViewModel) async {
        await viewModel.dictationShutdownTask?.value
        await viewModel.polishingShutdownTask?.value
        await viewModel.dictationWarmupTask?.value
        await viewModel.polishingWarmupTask?.value
    }

    private func makeViewModel(
        preflight: RecordingPreflight? = nil
    ) -> (DictationViewModel, SettingsStore, OnboardingTestBackendManager) {
        let suiteName = "localvoxtral.MistralAPIModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        settings.onboardingCompleted = true
        let backendManager = OnboardingTestBackendManager()
        let viewModel = DictationViewModel(
            settings: settings,
            backendManager: backendManager,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            localNetworkPermissionPreflight: preflight,
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)
        return (viewModel, settings, backendManager)
    }
}

@MainActor
private final class RecordingPreflight: LocalNetworkPermissionPreflighting {
    struct Request {
        let endpoint: URL
        let reason: String
    }

    private(set) var requests: [Request] = []

    func preflight(endpoint: URL, reason: String) {
        requests.append(Request(endpoint: endpoint, reason: reason))
    }
}

private final class FakeMistralAPIKeyVerifier: MistralAPIKeyVerifying {
    private let result: MistralAPIKeyVerification
    private let recorded = Mutex<[String]>([])

    init(result: MistralAPIKeyVerification) {
        self.result = result
    }

    var checkedKeys: [String] { recorded.withLock { $0 } }

    func verify(apiKey: String) async -> MistralAPIKeyVerification {
        recorded.withLock { $0.append(apiKey) }
        return result
    }
}

private final class FakeMistralModelLister: MistralModelListing {
    private let result: MistralModelListResult
    private let recorded = Mutex<[String]>([])

    init(result: MistralModelListResult) {
        self.result = result
    }

    var requestedKeys: [String] { recorded.withLock { $0 } }

    func listModels(apiKey: String) async -> MistralModelListResult {
        recorded.withLock { $0.append(apiKey) }
        return result
    }
}
