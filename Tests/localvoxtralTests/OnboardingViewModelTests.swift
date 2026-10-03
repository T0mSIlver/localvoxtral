import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuiteName = "localvoxtral.OnboardingViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        self.defaults = defaults
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = ""
        try await super.tearDown()
    }

    // MARK: - Fixture

    private func makeModel(
        keyVerification: MistralAPIKeyVerification = .accepted,
        secretStore: any SecretStoring = InMemorySecretStore()
    ) -> (
        model: OnboardingViewModel,
        settings: SettingsStore,
        driver: FakeOnboardingBootstrapDriver,
        closeCount: () -> Int,
        openEndpointsCount: () -> Int
    ) {
        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: secretStore)
        let manager = OnboardingTestBackendManager()
        let viewModel = DictationViewModel(
            settings: settings,
            backendManager: manager,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        // The wizard's key check must never reach api.mistral.ai from a test
        // or a preview.
        viewModel.engines.mistralAPIKeyVerifier = FakeOnboardingKeyVerifier(result: keyVerification)
        let driver = FakeOnboardingBootstrapDriver()
        let model = OnboardingViewModel(settings: settings, viewModel: viewModel, driver: driver)

        let closeBox = Counter()
        let openBox = Counter()
        model.onRequestClose = { closeBox.value += 1 }
        model.onOpenEndpointsSettings = { openBox.value += 1 }

        return (model, settings, driver, { closeBox.value }, { openBox.value })
    }

    private final class Counter { var value = 0 }

    // MARK: - Review findings (opencode, 2026-07-05)

    func testStartDownloadsForcesManagedModes() {
        let (model, settings, _, _, _) = makeModel()
        settings.dictationBackendMode = .externalURL
        settings.polishingBackendMode = .externalURL
        model.polishingConsent = true

        model.startDownloads()

        // Re-run Setup from external mode: downloading managed backends must
        // also switch the modes, or the download is dead weight.
        XCTAssertEqual(settings.dictationBackendMode, .managedLocal)
        XCTAssertEqual(settings.polishingBackendMode, .managedLocal)
    }

    func testStartDownloadsWithoutConsentLeavesPolishingModeAlone() {
        let (model, settings, _, _, _) = makeModel()
        settings.dictationBackendMode = .externalURL
        settings.polishingBackendMode = .externalURL
        model.polishingConsent = false

        model.startDownloads()

        XCTAssertEqual(settings.dictationBackendMode, .managedLocal)
        XCTAssertEqual(settings.polishingBackendMode, .externalURL)
        XCTAssertFalse(settings.llmPolishingEnabled)
    }

    func testUseOwnServerAfterConsentedDownloadDisablesPolishing() {
        let (model, settings, _, _, _) = makeModel()
        model.polishingConsent = true
        model.startDownloads()
        XCTAssertTrue(settings.llmPolishingEnabled)

        model.useOwnServer()

        // Leaving polishing enabled against the unconfigured default external
        // URL would fire a silently failing polish request on every commit.
        XCTAssertFalse(settings.llmPolishingEnabled)
        XCTAssertEqual(settings.dictationBackendMode, .externalURL)
        XCTAssertEqual(settings.polishingBackendMode, .externalURL)
    }

    // MARK: - Navigation

    func testAdvance_walksAllPagesInOrder() {
        let (model, _, _, _, _) = makeModel()

        XCTAssertEqual(model.page, .welcome)
        XCTAssertFalse(model.canGoBack)

        model.advance()
        XCTAssertEqual(model.page, .permissions)
        XCTAssertTrue(model.canGoBack)

        model.advance()
        XCTAssertEqual(model.page, .engine)
        XCTAssertEqual(model.engineChoice, .local, "local is the default choice")

        model.advance()
        XCTAssertEqual(model.page, .downloads)

        model.advance()
        XCTAssertEqual(model.page, .finish)
        XCTAssertTrue(model.isFinalPage)

        XCTAssertEqual(model.pageOrder, [.welcome, .permissions, .engine, .downloads, .finish])
    }

    func testAdvance_mistralPathSkipsTheDownloadsPage() {
        let (model, _, _, _, _) = makeModel()
        model.advance()  // permissions
        model.advance()  // engine
        model.engineChoice = .mistralAPI
        model.mistralAPIKeyDraft = "mk-mistral"

        XCTAssertEqual(model.pageOrder, [.welcome, .permissions, .engine, .finish])

        model.advance()

        XCTAssertEqual(model.page, .finish, "there is nothing to download for a hosted engine")
        XCTAssertTrue(model.isFinalPage)
    }

    func testGoBack_movesToPreviousPage() {
        let (model, _, _, _, _) = makeModel()
        model.advance()
        model.advance()
        model.advance()
        XCTAssertEqual(model.page, .downloads)

        model.goBack()
        XCTAssertEqual(model.page, .engine)

        model.goBack()
        XCTAssertEqual(model.page, .permissions)

        model.goBack()
        XCTAssertEqual(model.page, .welcome)
        // Cannot go back past the first page.
        model.goBack()
        XCTAssertEqual(model.page, .welcome)
    }

    func testGoBackFromFinish_routesByTheEngineThatWasChosen() {
        let (localModel, _, _, _, _) = makeModel()
        localModel.advance()  // permissions
        localModel.advance()  // engine
        localModel.advance()  // downloads
        localModel.advance()  // finish
        XCTAssertEqual(localModel.page, .finish)

        localModel.goBack()
        XCTAssertEqual(localModel.page, .downloads)

        let (mistralModel, _, _, _, _) = makeModel()
        mistralModel.advance()  // permissions
        mistralModel.advance()  // engine
        mistralModel.engineChoice = .mistralAPI
        mistralModel.mistralAPIKeyDraft = "mk-mistral"
        mistralModel.advance()  // finish (no downloads page was shown)
        XCTAssertEqual(mistralModel.page, .finish)

        mistralModel.goBack()
        XCTAssertEqual(
            mistralModel.page, .engine,
            "there was no downloads page to go back to"
        )
    }

    func testAdvanceOnFinalPage_finishesTheWizard() {
        let (model, settings, _, closeCount, _) = makeModel()
        model.advance()  // permissions
        model.advance()  // engine
        model.advance()  // downloads
        model.advance()  // finish
        XCTAssertEqual(model.page, .finish)

        model.advance()  // past finish → finish()

        XCTAssertTrue(settings.onboardingCompleted)
        XCTAssertEqual(closeCount(), 1)
    }


    // MARK: - Engine choice

    func testEnginePage_mistralPathSetsBothModes_enablesPolishing_andNeverDownloads() {
        let (model, settings, driver, _, _) = makeModel()
        model.advance()  // permissions
        model.advance()  // engine
        model.engineChoice = .mistralAPI
        model.mistralAPIKeyDraft = "  mk-mistral  "

        model.advance()

        XCTAssertEqual(settings.mistralAPIKey, "mk-mistral")
        XCTAssertEqual(settings.dictationBackendMode, .mistralAPI)
        XCTAssertEqual(settings.polishingBackendMode, .mistralAPI)
        XCTAssertTrue(settings.llmPolishingEnabled)
        XCTAssertEqual(driver.startCallCount, 0, "a hosted engine downloads nothing")
        XCTAssertEqual(driver.cancelCallCount, 1, "any local download in flight is cancelled")
        XCTAssertEqual(model.page, .finish)
    }

    /// #1624: a key the Keychain refused keeps the wizard on the engine page
    /// with the failure shown, and moves no engine.
    func testEnginePage_aKeyTheKeychainRefusesStopsOnTheEnginePage() {
        let (model, settings, driver, _, _) = makeModel(
            secretStore: FakeSecretStore(writeFailures: [.mistralAPIKey])
        )
        model.advance()  // permissions
        model.advance()  // engine
        let before = (settings.dictationBackendMode, settings.polishingBackendMode)
        model.engineChoice = .mistralAPI
        model.mistralAPIKeyDraft = "mk-mistral"

        model.advance()

        XCTAssertEqual(model.page, .engine)
        XCTAssertEqual(model.mistralAPIKeySaveFailure, SettingsStore.secretStoreWriteFailureSummary)
        XCTAssertEqual(settings.dictationBackendMode, before.0)
        XCTAssertEqual(settings.polishingBackendMode, before.1)
        XCTAssertEqual(driver.cancelCallCount, 0)

        // Editing the key clears the failure; the next Continue tries again.
        model.mistralAPIKeyDraft = "mk-mistral-2"
        XCTAssertNil(model.mistralAPIKeySaveFailure)
    }

    /// Local → Begin download → back → Mistral → Continue → back → Local →
    /// Continue must land on a Downloads page that re-offers "Begin download"
    /// and, once pressed, moves the engines back to managed. Before the fix the
    /// stale `downloadsStarted` flag hid the button, `startDownloads()` was
    /// unreachable, and Finish read "runs on this Mac" while both engines were
    /// still on Mistral (GLM review, 2026-09-16).
    func testEnginePage_flipFlopBackToLocalReoffersTheDownloadAndRestoresManagedEngines() {
        let (model, settings, driver, _, _) = makeModel()
        model.advance()  // permissions
        model.advance()  // engine
        model.advance()  // downloads (local)
        model.startDownloads()
        XCTAssertTrue(model.downloadsStarted)
        XCTAssertEqual(driver.startCallCount, 1)

        model.goBack()  // engine
        model.engineChoice = .mistralAPI
        model.mistralAPIKeyDraft = "mk-mistral"
        model.advance()  // finish (Mistral path)
        XCTAssertEqual(model.page, .finish)
        XCTAssertEqual(settings.dictationBackendMode, .mistralAPI)
        XCTAssertEqual(driver.cancelCallCount, 1)
        XCTAssertFalse(
            model.downloadsStarted,
            "a cancelled download is no download — the flag must not survive the Mistral choice"
        )

        model.goBack()  // engine
        model.engineChoice = .local
        model.advance()  // downloads
        XCTAssertEqual(model.page, .downloads)
        XCTAssertFalse(model.downloadsStarted, "Begin download is offered again")

        model.startDownloads()
        XCTAssertEqual(driver.startCallCount, 2, "the local download runs again")
        XCTAssertEqual(settings.dictationBackendMode, .managedLocal)
        XCTAssertEqual(settings.polishingBackendMode, .managedLocal)

        model.advance()  // finish
        XCTAssertEqual(model.page, .finish)
        XCTAssertEqual(model.engineSummary, "Dictation and polishing run on this Mac.")
        XCTAssertEqual(
            settings.dictationBackendMode, .managedLocal,
            "the summary and the engines agree"
        )
    }

    /// Mistral → Continue → back → Local → decline polishing → Begin download
    /// must leave no hosted polishing behind: the Mistral choice turned it on,
    /// and the Local path only touches polishing when the user consents.
    func testReturningFromMistralToLocalWithoutPolishingDisablesHostedRequests() {
        let (model, settings, _, _, _) = makeModel()
        model.advance()  // permissions
        model.advance()  // engine
        model.engineChoice = .mistralAPI
        model.mistralAPIKeyDraft = "mk-mistral"
        model.advance()  // finish (Mistral path)
        XCTAssertTrue(settings.llmPolishingEnabled)

        model.goBack()  // engine
        model.engineChoice = .local
        model.advance()  // downloads
        model.polishingConsent = false
        model.startDownloads()

        XCTAssertEqual(settings.dictationBackendMode, .managedLocal)
        XCTAssertFalse(settings.llmPolishingEnabled, "declined polishing must not keep Mistral's")
        XCTAssertNotEqual(settings.polishingBackendMode, .mistralAPI)
    }

    func testEnginePage_localPathIsUnchanged() {
        let (model, settings, driver, _, _) = makeModel()
        model.advance()  // permissions
        model.advance()  // engine

        model.advance()  // downloads
        XCTAssertEqual(model.page, .downloads)
        XCTAssertEqual(driver.startCallCount, 0, "nothing runs before Begin download")
        XCTAssertEqual(settings.mistralAPIKey, "")

        model.startDownloads()

        XCTAssertEqual(driver.startCallCount, 1)
        XCTAssertEqual(settings.dictationBackendMode, .managedLocal)
        XCTAssertEqual(settings.polishingBackendMode, .managedLocal)
    }

    func testEnginePage_emptyKeyBlocksContinue() {
        let (model, settings, _, _, _) = makeModel()
        model.advance()  // permissions
        model.advance()  // engine
        model.engineChoice = .mistralAPI

        XCTAssertFalse(model.canContinue)
        model.advance()
        XCTAssertEqual(model.page, .engine, "Continue does nothing without a key")
        XCTAssertEqual(settings.dictationBackendMode, .managedLocal)

        // Whitespace is not a key.
        model.mistralAPIKeyDraft = "   "
        XCTAssertFalse(model.canContinue)

        model.mistralAPIKeyDraft = "mk-mistral"
        XCTAssertTrue(model.canContinue)
    }

    func testEnginePage_localChoiceNeverBlocksContinue() {
        let (model, _, _, _, _) = makeModel()
        model.advance()  // permissions
        model.advance()  // engine

        XCTAssertTrue(model.canContinue)
        XCTAssertTrue(model.mistralAPIKeyDraft.isEmpty)
    }

    func testEnginePage_rejectedKeyIsAdvisoryAndDoesNotBlockContinue() async {
        let (model, settings, _, _, _) = makeModel(
            keyVerification: .rejected(statusCode: 401)
        )
        model.advance()  // permissions
        model.advance()  // engine
        model.engineChoice = .mistralAPI
        model.mistralAPIKeyDraft = "mk-wrong"

        model.checkMistralAPIKeyDraft()
        await model.mistralAPIKeyCheckTask?.value

        XCTAssertEqual(
            model.mistralAPIKeyCheckState, .finished(.rejected(statusCode: 401))
        )
        XCTAssertEqual(model.mistralAPIKeyCheckState.statusLine, "Rejected (HTTP 401)")
        // The check is advisory: it can be wrong (offline, proxy, a key minted
        // seconds ago), and the owner still gets to proceed.
        XCTAssertTrue(model.canContinue)

        model.advance()
        XCTAssertEqual(model.page, .finish)
        XCTAssertEqual(settings.dictationBackendMode, .mistralAPI)
    }

    /// A verdict belongs to the key it checked: editing the key clears it,
    /// and a check still running for the old key does not publish (#1626).
    func testEditingTheKeyDuringItsCheckDropsTheOldVerdict() async {
        let (model, _, _, _, _) = makeModel()
        let verifier = GatedOnboardingKeyVerifier(checks: 1)
        model.viewModel.engines.mistralAPIKeyVerifier = verifier
        model.engineChoice = .mistralAPI
        model.mistralAPIKeyDraft = "mk-good"

        model.checkMistralAPIKeyDraft()
        model.mistralAPIKeyDraft = "mk-typo"
        verifier.answer(check: 0, with: .accepted)
        await model.mistralAPIKeyCheckTask?.value

        XCTAssertEqual(model.mistralAPIKeyCheckState, .idle)
    }

    /// The same key typed again and checked again: the first check, still
    /// out, must not overwrite the second's verdict.
    func testAnOlderCheckOfTheSameKeyDoesNotOverwriteANewerOne() async {
        let (model, _, _, _, _) = makeModel()
        let verifier = GatedOnboardingKeyVerifier(checks: 2)
        model.viewModel.engines.mistralAPIKeyVerifier = verifier
        model.engineChoice = .mistralAPI
        model.mistralAPIKeyDraft = "mk-good"

        model.checkMistralAPIKeyDraft()
        let firstCheck = model.mistralAPIKeyCheckTask
        await verifier.nextCheckStarted()
        model.mistralAPIKeyDraft = "mk-goo"
        model.mistralAPIKeyDraft = "mk-good"
        model.checkMistralAPIKeyDraft()
        await verifier.nextCheckStarted()
        verifier.answer(check: 1, with: .accepted)
        await model.mistralAPIKeyCheckTask?.value
        verifier.answer(check: 0, with: .unreachable("timed out"))
        await firstCheck?.value

        XCTAssertEqual(model.mistralAPIKeyCheckState, .finished(.accepted))
    }

    func testEditingTheKeyAfterItsCheckClearsTheVerdict() async {
        let (model, _, _, _, _) = makeModel(keyVerification: .accepted)
        model.engineChoice = .mistralAPI
        model.mistralAPIKeyDraft = "mk-good"
        model.checkMistralAPIKeyDraft()
        await model.mistralAPIKeyCheckTask?.value
        XCTAssertEqual(model.mistralAPIKeyCheckState, .finished(.accepted))

        model.mistralAPIKeyDraft = "mk-typo"

        XCTAssertEqual(model.mistralAPIKeyCheckState, .idle)
    }

    func testEngineSummaryNamesTheEngineThatWasSetUp() {
        let (model, _, _, _, _) = makeModel()

        XCTAssertEqual(model.engineSummary, "Dictation and polishing run on this Mac.")

        model.engineChoice = .mistralAPI
        XCTAssertEqual(
            model.engineSummary,
            "Dictation and polishing use Mistral's hosted models."
        )
    }

    // MARK: - Downloads consent wiring

    func testStartDownloads_consentOn_downloadsPolishingAndEnablesIt() {
        let (model, settings, driver, _, _) = makeModel()
        XCTAssertTrue(model.polishingConsent)  // default ON
        XCTAssertFalse(settings.llmPolishingEnabled)

        model.startDownloads()

        XCTAssertTrue(model.downloadsStarted)
        XCTAssertEqual(driver.startCallCount, 1)
        XCTAssertEqual(driver.lastStart?.dictation, true)
        XCTAssertEqual(driver.lastStart?.polishing, true)
        XCTAssertTrue(settings.llmPolishingEnabled)
    }

    func testStartDownloads_consentOff_skipsPolishingAndLeavesItDisabled() {
        let (model, settings, driver, _, _) = makeModel()
        model.polishingConsent = false

        model.startDownloads()

        XCTAssertEqual(driver.lastStart?.dictation, true)
        XCTAssertEqual(driver.lastStart?.polishing, false)
        XCTAssertFalse(settings.llmPolishingEnabled)
    }

    /// A first run that turned polishing on and was force-quit before the
    /// wizard closed leaves it on. Declining it on the next run must turn it
    /// off, or the warmup when the wizard closes downloads it anyway (#1625).
    func testDecliningPolishingAfterAnInterruptedRunTurnsItOff() {
        let (model, settings, driver, _, _) = makeModel()
        settings.polishingBackendMode = .managedLocal
        settings.llmPolishingEnabled = true
        model.polishingConsent = false

        model.startDownloads()

        XCTAssertEqual(driver.lastStart?.polishing, false)
        XCTAssertFalse(settings.llmPolishingEnabled)
        XCTAssertFalse(model.viewModel.engines.isManagedPolishingWarmupWanted)
    }

    func testStartDownloads_isIdempotent() {
        let (model, _, driver, _, _) = makeModel()

        model.startDownloads()
        model.startDownloads()

        XCTAssertEqual(driver.startCallCount, 1)
    }

    // MARK: - "I run my own server instead"

    func testUseOwnServer_setsBothModesExternal_completes_opensEndpoints_andCloses() {
        let (model, settings, driver, closeCount, openEndpointsCount) = makeModel()

        model.useOwnServer()

        XCTAssertEqual(settings.dictationBackendMode, .externalURL)
        XCTAssertEqual(settings.polishingBackendMode, .externalURL)
        XCTAssertTrue(settings.onboardingCompleted)
        XCTAssertEqual(driver.cancelCallCount, 1)
        XCTAssertEqual(openEndpointsCount(), 1)
        XCTAssertEqual(closeCount(), 1)
    }

    // MARK: - Terminal actions

    func testFinish_completesAndCloses() {
        let (model, settings, _, closeCount, _) = makeModel()

        model.finish()

        XCTAssertTrue(settings.onboardingCompleted)
        XCTAssertEqual(closeCount(), 1)
    }

    func testSkip_completesAndCloses() {
        let (model, settings, _, closeCount, _) = makeModel()

        model.skip()

        XCTAssertTrue(settings.onboardingCompleted)
        XCTAssertEqual(closeCount(), 1)
    }

    func testCompleteOnboarding_isIdempotent_doesNotDoubleClose() {
        let (model, settings, _, closeCount, _) = makeModel()

        model.completeOnboarding()
        model.completeOnboarding()

        XCTAssertTrue(settings.onboardingCompleted)
        // completeOnboarding never closes on its own.
        XCTAssertEqual(closeCount(), 0)
    }
}

/// Answers the wizard's key check without a socket.
private final class FakeOnboardingKeyVerifier: MistralAPIKeyVerifying {
    private let result: MistralAPIKeyVerification

    init(result: MistralAPIKeyVerification) {
        self.result = result
    }

    func verify(apiKey: String) async -> MistralAPIKeyVerification { result }
}

/// Answers each of the wizard's key checks, in the order they start, only
/// when the test releases that check's verdict.
private final class GatedOnboardingKeyVerifier: MistralAPIKeyVerifying {
    private let verdicts: [AsyncStream<MistralAPIKeyVerification>]
    private let releases: [AsyncStream<MistralAPIKeyVerification>.Continuation]
    private let starts: AsyncStream<Void>
    private let startsContinuation: AsyncStream<Void>.Continuation
    private let started = Mutex(0)

    init(checks: Int) {
        let pairs = (0..<checks).map { _ in AsyncStream<MistralAPIKeyVerification>.makeStream() }
        verdicts = pairs.map(\.stream)
        releases = pairs.map(\.continuation)
        (starts, startsContinuation) = AsyncStream.makeStream()
    }

    func answer(check: Int, with verdict: MistralAPIKeyVerification) {
        releases[check].yield(verdict)
    }

    /// Returns once one more check has reached the verifier, so the test
    /// knows which index the next check takes.
    func nextCheckStarted() async {
        for await _ in starts { return }
    }

    func verify(apiKey: String) async -> MistralAPIKeyVerification {
        let index = started.withLock { count in
            defer { count += 1 }
            return count
        }
        startsContinuation.yield()
        for await verdict in verdicts[index] { return verdict }
        return .accepted
    }
}
