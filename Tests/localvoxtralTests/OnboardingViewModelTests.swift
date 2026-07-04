import Foundation
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

    private func makeModel() -> (
        model: OnboardingViewModel,
        settings: SettingsStore,
        driver: PreviewOnboardingBootstrapDriver,
        closeCount: () -> Int,
        openEndpointsCount: () -> Int
    ) {
        let settings = SettingsStore(defaults: defaults, environment: [:])
        let manager = OnboardingTestBackendManager()
        let viewModel = DictationViewModel(
            settings: settings,
            backendManager: manager,
            overlayBufferCoordinator: OnboardingNoopOverlayCoordinator(),
            startRuntimeServices: false
        )
        let driver = PreviewOnboardingBootstrapDriver()
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
        XCTAssertEqual(model.page, .downloads)

        model.advance()
        XCTAssertEqual(model.page, .finish)
        XCTAssertTrue(model.isFinalPage)
    }

    func testGoBack_movesToPreviousPage() {
        let (model, _, _, _, _) = makeModel()
        model.advance()
        model.advance()
        XCTAssertEqual(model.page, .downloads)

        model.goBack()
        XCTAssertEqual(model.page, .permissions)

        model.goBack()
        XCTAssertEqual(model.page, .welcome)
        // Cannot go back past the first page.
        model.goBack()
        XCTAssertEqual(model.page, .welcome)
    }

    func testAdvanceOnFinalPage_finishesTheWizard() {
        let (model, settings, _, closeCount, _) = makeModel()
        model.advance()  // permissions
        model.advance()  // downloads
        model.advance()  // finish
        XCTAssertEqual(model.page, .finish)

        model.advance()  // past finish → finish()

        XCTAssertTrue(settings.onboardingCompleted)
        XCTAssertEqual(closeCount(), 1)
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

@MainActor
private final class OnboardingNoopOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitTargetAppPID: pid_t? = nil

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(targetRect: .zero, source: .windowCenter)
    }
    func startSession(preResolvedAnchor: OverlayAnchor?) {}
    func beginFinalizing(displayBufferText: String, commitBufferText: String) {}
    func refresh(displayBufferText: String, commitBufferText: String) {}
    @discardableResult
    func commitIfNeeded(
        using textCommitter: OverlayTextCommitting, autoCopyEnabled: Bool
    ) -> OverlayBufferCommitOutcome {
        .succeeded
    }
    func dismissAfterHold(minimumVisibility: TimeInterval) {}
    func reset() {}
    func captureLiveCommitTargetAppPID() {}
}
