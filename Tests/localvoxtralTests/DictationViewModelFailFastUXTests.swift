import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class DictationViewModelFailFastUXTests: XCTestCase {
    // DictationViewModel owns several app-lifetime services. Retain test instances
    // for the process duration so teardown does not race service shutdown.
    private static var retainedViewModels: [DictationViewModel] = []

    // MARK: - Backend connection failure messaging

    func testSocketConnectionRefusedSurfacesRefusedStatusAndEndpoint() {
        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        viewModel.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        let endpoint = viewModel.sanitizedRealtimeEndpointForMessageReference()
        XCTAssertTrue(endpoint.contains("ws://"), "sanity: endpoint resolved, got \(endpoint)")

        viewModel.handleConnectFailure(
            reason: .socketError(
                message: "WebSocket failed: [NSURLErrorDomain:-1004] url=ws://127.0.0.1:8000/v1/realtime"
            )
        )

        XCTAssertEqual(viewModel.statusText, "Connection refused.")
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertTrue(viewModel.lastError?.contains(endpoint) == true, "lastError should name the endpoint")
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
    }

    func testSocketHostUnreachableSurfacesDistinctStatus() {
        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        viewModel.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        viewModel.handleConnectFailure(
            reason: .socketError(message: "WebSocket failed: [NSURLErrorDomain:-1003] url=ws://x/realtime")
        )

        XCTAssertEqual(viewModel.statusText, "Host unreachable.")
        XCTAssertNotNil(viewModel.lastError)
    }

    func testTimeoutReasonKeepsStableStatusAndEndpointPhrase() {
        let viewModel = makeViewModel(outputMode: .overlayBuffer)
        viewModel.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        let endpoint = viewModel.sanitizedRealtimeEndpointForMessageReference()

        viewModel.handleConnectFailure(reason: .timedOut(timeoutSeconds: TimingConstants.connectTimeout))

        XCTAssertEqual(viewModel.statusText, "Connection timed out.")
        XCTAssertTrue(
            viewModel.lastError?.contains(
                "No connection response received in \(Self.formattedTimeout(TimingConstants.connectTimeout))"
            ) == true
        )
        XCTAssertTrue(viewModel.lastError?.contains(endpoint) == true)
    }

    func testRefusedSocketErrorDuringTimeoutResolutionWinsOverTimeout() async {
        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.isConnectingRealtimeSession = true
        viewModel.statusText = "Connecting to realtime backend..."
        retainForTestProcessLifetime(viewModel)

        await viewModel.resolveConnectTimeout(timeoutSeconds: TimingConstants.connectTimeout) { _ in
            viewModel.handle(
                event: .error(
                    "WebSocket failed: The operation couldn't be completed. [NSURLErrorDomain:-1004] url=ws://127.0.0.1:8001/v1/realtimeaa"
                )
            )
        }

        XCTAssertFalse(viewModel.isConnectingRealtimeSession)
        XCTAssertEqual(viewModel.statusText, "Connection refused.")
        XCTAssertTrue(viewModel.lastError?.contains("Connection refused") == true)
        XCTAssertFalse(viewModel.lastError?.contains("No connection response received") == true)
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
    }

    func testEndpointRejectedSocketErrorSurfacesPathStatus() {
        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        viewModel.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        viewModel.handleConnectFailure(
            reason: .socketError(
                message: "WebSocket failed: bad server response [NSURLErrorDomain:-1011] url=ws://127.0.0.1:8000/v1/realtimeaa"
            )
        )

        XCTAssertEqual(viewModel.statusText, "Endpoint path rejected.")
        XCTAssertTrue(viewModel.lastError?.contains("Check the path") == true)
    }

    func testInvalidEndpointReasonSurfacesSettingsGuidance() {
        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        viewModel.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        viewModel.handleConnectFailure(reason: .invalidEndpoint)

        XCTAssertEqual(viewModel.statusText, "Invalid endpoint URL.")
        XCTAssertTrue(viewModel.lastError?.contains("Settings") == true)
    }

    func testNetworkLostReasonSurfacesNetworkLostStatus() {
        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        viewModel.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        viewModel.handleConnectFailure(reason: .networkLost)

        XCTAssertEqual(viewModel.statusText, "Network lost. Dictation stopped.")
        XCTAssertNotNil(viewModel.lastError)
    }

    func testConnectionFailurePopoverDetailDoesNotRepeatStatusText() {
        let status = "Connection refused."
        let endpoint = "ws://127.0.0.1:8001/v1/realtimeaa"
        let detail = StatusPopoverConnectionFailurePresenter.detail(
            statusText: status,
            lastError: "Connection refused at \(endpoint). Make sure the backend is running and the port is correct.",
            endpoint: endpoint
        )

        XCTAssertEqual(detail, "Endpoint: \(endpoint)")
        XCTAssertFalse(detail?.contains(status) == true)
    }

    // MARK: - Accessibility gate at dictation start

    func testLiveAutoPasteWarningPresentIffNotTrusted() {
        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        retainForTestProcessLifetime(viewModel)

        viewModel.textInsertion.debugSetAccessibilityTrusted(false)
        XCTAssertEqual(
            viewModel.liveAutoPasteAccessibilityWarning,
            DictationViewModel.liveAutoPasteAccessibilityWarningMessage
        )

        viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        XCTAssertNil(viewModel.liveAutoPasteAccessibilityWarning)
    }

    func testOverlayModeNeverShowsLiveAutoPasteWarning() {
        let viewModel = makeViewModel(outputMode: .overlayBuffer)
        retainForTestProcessLifetime(viewModel)

        viewModel.textInsertion.debugSetAccessibilityTrusted(false)
        XCTAssertNil(viewModel.liveAutoPasteAccessibilityWarning)
    }

    func testErrorlessDisconnectDoesNotLeakUIErrorIntoFailureDetails() {
        // A handshake that closes without a websocket .error event classifies
        // from lastSocketErrorMessage (nil here), never from lastError, which
        // may hold unrelated UI state such as the Accessibility warning.
        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        viewModel.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        viewModel.lastError = DictationViewModel.liveAutoPasteAccessibilityWarningMessage
        viewModel.isConnectingRealtimeSession = true

        viewModel.handle(event: .disconnected)

        XCTAssertFalse(
            viewModel.debugLastConnectFailureTechnicalDetails?.contains("Accessibility") == true,
            "failure details must not embed the AX warning, got: \(viewModel.debugLastConnectFailureTechnicalDetails ?? "nil")"
        )
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
    }

    func testWarningIsRecognizedAsAccessibilityErrorToken() {
        // Ensures the existing onAccessibilityTrustChanged callback (which clears
        // lastError when currentErrorToken == .accessibilityPermissionRequired)
        // will clear the warning once Accessibility lands.
        let token = DictationViewModel.ErrorToken.from(
            DictationViewModel.liveAutoPasteAccessibilityWarningMessage
        )
        XCTAssertEqual(token, .accessibilityPermissionRequired)
    }

    func testBeginDictationSessionSurfacesAccessibilityWarningInLiveMode() async {
        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        // Point at a closed port so the async connect fails fast and does not
        // hit a real backend. The AX warning is asserted synchronously, before
        // any connect result can race back.
        viewModel.settings.realtimeAPIEndpointURL = "ws://127.0.0.1:65535/realtime"
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.textInsertion.debugSetAccessibilityTrusted(false)
        retainForTestProcessLifetime(viewModel)

        await viewModel.beginDictationSession()

        // Fail-fast warning surfaces at start and is not clobbered by the
        // generic "Connecting..." status.
        XCTAssertEqual(viewModel.statusText, "Paste blocked by Accessibility permission.")
        XCTAssertEqual(viewModel.lastError, DictationViewModel.liveAutoPasteAccessibilityWarningMessage)
        XCTAssertTrue(viewModel.isConnectingRealtimeSession, "session still proceeds so AX can be granted mid-session")

        viewModel.abortConnectingSession()
    }

    func testBeginDictationSessionSkipsAccessibilityWarningWhenTrustedInLiveMode() async {
        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        viewModel.settings.realtimeAPIEndpointURL = "ws://127.0.0.1:65535/realtime"
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        retainForTestProcessLifetime(viewModel)

        await viewModel.beginDictationSession()

        XCTAssertEqual(viewModel.statusText, "Connecting to realtime backend...")
        XCTAssertNil(viewModel.lastError)

        viewModel.abortConnectingSession()
    }

    func testBeginDictationSessionSkipsAccessibilityWarningInOverlayMode() async {
        let viewModel = makeViewModel(outputMode: .overlayBuffer)
        viewModel.settings.realtimeAPIEndpointURL = "ws://127.0.0.1:65535/realtime"
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.textInsertion.debugSetAccessibilityTrusted(false)
        retainForTestProcessLifetime(viewModel)

        await viewModel.beginDictationSession()

        XCTAssertEqual(viewModel.statusText, "Connecting to realtime backend...")
        XCTAssertNil(viewModel.lastError)

        viewModel.abortConnectingSession()
    }

    func testStartupPermissionPromptsAreSkippedUntilOnboardingCompletes() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.onboardingCompleted = false
        let viewModel = DictationViewModel(
            settings: settings,
            backendManager: FakeManagedBackendManager(),
            overlayBufferCoordinator: NoopOverlayCoordinator(),
            startRuntimeServices: true
        )

        XCTAssertFalse(viewModel.debugHasRequestedStartupPermissions)
    }

    // MARK: - Managed backend startup

    func testStartDictationManagedBothWithPolishingEnabledRequestsBothBackends() async {
        let backendManager = FakeManagedBackendManager()
        backendManager.suspendEnsure = true
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        // This test reaches beginDictationSession, which arms the real
        // connect-timeout timer on a process-retained view model; without
        // this suppression the timer's failure alert fires ~10s later inside
        // whatever test is then running (field flake, 2026-07-05).
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.debugMicrophoneAuthorizationStatusOverride = .authorized
        retainForTestProcessLifetime(viewModel)

        viewModel.startDictation()
        await backendManager.waitUntilEnsureStarted()
        backendManager.resumeEnsure()
        await viewModel.managedStartupTask?.value

        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: true, polishing: true)])
    }

    func testStartDictationInManagedModeAwaitsBackendManagerAndSurfacesFailure() async {
        let backendManager = FakeManagedBackendManager()
        backendManager.ensureError = FakeManagedBackendFailure(
            message: "Dictation engine failed: model unavailable"
        )
        backendManager.suspendEnsure = true
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.debugMicrophoneAuthorizationStatusOverride = .authorized
        retainForTestProcessLifetime(viewModel)

        viewModel.startDictation()
        await backendManager.waitUntilEnsureStarted()

        XCTAssertTrue(viewModel.isConnectingRealtimeSession)
        XCTAssertNil(viewModel.sessionProvider, "connection must not start until the managed backend is ready")
        XCTAssertEqual(viewModel.statusText, "Starting dictation backend...")
        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: true, polishing: false)])

        backendManager.resumeEnsure()
        // A bare Task.yield() races the startup task's failure continuation
        // (seen flaking in CI); await the tracked task instead.
        await viewModel.managedStartupTask?.value

        XCTAssertFalse(viewModel.isConnectingRealtimeSession)
        XCTAssertEqual(viewModel.statusText, "Managed backend failed.")
        // Popover rule (AGENTS.md): lastError is one short sentence; the full
        // failure summary stays in the alert/log, not the popover. This fake
        // is not a ManagedBackendManagerError, so the generic wording applies.
        XCTAssertEqual(viewModel.lastError, "Managed backend failed to start.")
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
    }

    func testManagedStartupFailureKeepsStderrOutOfLastErrorButPreservesTechnicalDetails() async {
        let marker = "FAKE_STDERR_TRACEBACK"
        let backendManager = FakeManagedBackendManager()
        backendManager.ensureError = ManagedBackendManagerError.backendFailed(
            name: "mlx-lm",
            summary: "mlx-lm exited 5 consecutive times.",
            detail: "stderr: Python traceback \(marker)"
        )
        backendManager.suspendEnsure = true
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .externalURL
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.debugMicrophoneAuthorizationStatusOverride = .authorized
        retainForTestProcessLifetime(viewModel)

        viewModel.startDictation()
        await backendManager.waitUntilEnsureStarted()

        backendManager.resumeEnsure()
        await viewModel.managedStartupTask?.value

        XCTAssertEqual(viewModel.statusText, "Managed backend failed.")
        XCTAssertEqual(viewModel.lastError, "mlx-lm failed to start.")
        XCTAssertFalse(viewModel.lastError?.contains("exited 5 consecutive times") == true)
        XCTAssertFalse(viewModel.lastError?.contains(marker) == true)
        XCTAssertTrue(viewModel.debugLastConnectFailureTechnicalDetails?.contains(marker) == true)
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
    }

    func testManagedStartupShowsDictationModelDownloadProgress() async {
        let backendManager = FakeManagedBackendManager()
        backendManager.suspendEnsure = true
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.debugMicrophoneAuthorizationStatusOverride = .authorized
        retainForTestProcessLifetime(viewModel)

        viewModel.startDictation()
        await backendManager.waitUntilEnsureStarted()

        await emitStatusAndAwaitMirror(
            backendManager, viewModel: viewModel,
            spec: BackendCatalog.speechd,
            status: .preparingModel(progress: ModelDownloadProgress(downloadedBytes: 36, totalBytes: 100))
        )

        XCTAssertEqual(viewModel.statusText, "Downloading dictation model (36%)...")

        backendManager.ensureError = FakeManagedBackendFailure(message: "cancelled")
        backendManager.resumeEnsure()
        await viewModel.managedStartupTask?.value
    }

    func testManagedStartupShowsPolishingModelDownloadProgress() async {
        let backendManager = FakeManagedBackendManager()
        backendManager.suspendEnsure = true
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .externalURL
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.debugMicrophoneAuthorizationStatusOverride = .authorized
        retainForTestProcessLifetime(viewModel)

        viewModel.startDictation()
        await backendManager.waitUntilEnsureStarted()

        await emitStatusAndAwaitMirror(
            backendManager, viewModel: viewModel,
            spec: BackendCatalog.polishd,
            status: .preparingModel(progress: ModelDownloadProgress(downloadedBytes: 1, totalBytes: 4))
        )

        XCTAssertEqual(viewModel.statusText, "Downloading polishing model (25%)...")

        backendManager.ensureError = FakeManagedBackendFailure(message: "cancelled")
        backendManager.resumeEnsure()
        await viewModel.managedStartupTask?.value
    }

    func testStartDictationInExternalModeNeverTouchesManagedBackendManager() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .externalURL
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.settings.realtimeAPIEndpointURL = ""
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.debugMicrophoneAuthorizationStatusOverride = .authorized
        retainForTestProcessLifetime(viewModel)

        viewModel.startDictation()
        // The external path now hops through the startup task before
        // beginDictationSession runs; the endpoint error surfaces when it
        // completes, and the backend manager must still never be touched.
        await viewModel.managedStartupTask?.value

        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
        XCTAssertEqual(viewModel.statusText, "Invalid endpoint URL.")
    }

    func testStartDictationWithExternalDictationAndManagedPolishingBootstrapsPolishingOnlyAndSurfacesFailure() async {
        let backendManager = FakeManagedBackendManager()
        backendManager.ensureError = ManagedBackendManagerError.backendFailed(
            name: "mlx-lm",
            summary: "mlx-lm exited 5 consecutive times.",
            detail: "stderr"
        )
        backendManager.suspendEnsure = true
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .externalURL
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.realtimeAPIEndpointURL = "ws://127.0.0.1:65535/realtime"
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.debugMicrophoneAuthorizationStatusOverride = .authorized
        retainForTestProcessLifetime(viewModel)

        viewModel.startDictation()
        await backendManager.waitUntilEnsureStarted()

        XCTAssertTrue(viewModel.isConnectingRealtimeSession)
        XCTAssertEqual(viewModel.statusText, "Starting polishing backend...")
        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: false, polishing: true)])

        backendManager.resumeEnsure()
        await viewModel.managedStartupTask?.value

        XCTAssertFalse(viewModel.isConnectingRealtimeSession)
        XCTAssertEqual(viewModel.statusText, "Managed backend failed.")
        XCTAssertEqual(viewModel.lastError, "mlx-lm failed to start.")
        XCTAssertEqual(viewModel.realtimeSessionIndicatorState, .recentFailure)
    }

    func testStartDictationWithManagedDictationAndExternalPolishingBootstrapsDictationOnly() async {
        let backendManager = FakeManagedBackendManager()
        backendManager.suspendEnsure = true
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.settings.llmPolishingEnabled = true
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.debugMicrophoneAuthorizationStatusOverride = .authorized
        retainForTestProcessLifetime(viewModel)

        viewModel.startDictation()
        await backendManager.waitUntilEnsureStarted()

        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: true, polishing: false)])

        backendManager.resumeEnsure()
        await viewModel.managedStartupTask?.value
        viewModel.abortConnectingSession()
    }

    func testManagedStartupCancelledByModeSwitchDoesNotBeginSessionOrSurfaceError() async {
        let backendManager = FakeManagedBackendManager()
        backendManager.suspendEnsure = true
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.settings.dictationShortcutMode = .pushToTalk
        viewModel.settings.realtimeAPIEndpointURL = ""
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.debugMicrophoneAuthorizationStatusOverride = .authorized
        retainForTestProcessLifetime(viewModel)

        viewModel.debugHandleDictationShortcutPressForTesting()
        await backendManager.waitUntilEnsureStarted()

        XCTAssertTrue(viewModel.isConnectingRealtimeSession)
        XCTAssertNil(viewModel.sessionProvider)

        viewModel.applyDictationBackendModeChange(.externalURL)
        viewModel.debugHandleDictationShortcutReleaseForTesting()
        backendManager.resumeEnsure()
        await viewModel.managedStartupTask?.value
        await Task.yield()

        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: true, polishing: false)])
        XCTAssertNil(viewModel.sessionProvider)
        XCTAssertFalse(viewModel.isDictating)
        XCTAssertFalse(viewModel.isConnectingRealtimeSession)
        XCTAssertNil(viewModel.lastError)
        XCTAssertNotEqual(viewModel.statusText, "Invalid endpoint URL.")
    }

    func testDictationModeSwitchAwayFromManagedStopsDictationOnly() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.polishingBackendMode = .managedLocal
        retainForTestProcessLifetime(viewModel)

        viewModel.applyDictationBackendModeChange(.externalURL)
        await backendManager.waitForStopDictationCallCount(1)

        XCTAssertEqual(backendManager.stopDictationCallCount, 1)
        XCTAssertEqual(backendManager.stopPolishingCallCount, 0)
        XCTAssertEqual(backendManager.stopAllCallCount, 0)
    }

    func testPolishingModeSwitchAwayFromManagedStopsPolishingOnly() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.polishingBackendMode = .managedLocal
        retainForTestProcessLifetime(viewModel)

        viewModel.applyPolishingBackendModeChange(.externalURL)
        await backendManager.waitForStopPolishingCallCount(1)

        XCTAssertEqual(backendManager.stopDictationCallCount, 0)
        XCTAssertEqual(backendManager.stopPolishingCallCount, 1)
        XCTAssertEqual(backendManager.stopAllCallCount, 0)
    }

    func testManagedPolishingModelChangePersistsAndStopsPolishingWhenDisabled() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = false
        retainForTestProcessLifetime(viewModel)

        let externalModelBefore = viewModel.settings.llmPolishingModel
        viewModel.applyLLMPolishingModelChange("example/new-polishing-model")
        await viewModel.polishingShutdownTask?.value

        XCTAssertEqual(viewModel.settings.managedLLMPolishingModel, "example/new-polishing-model")
        // The external-mode model NAME lives in a separate key and must not move.
        XCTAssertEqual(viewModel.settings.llmPolishingModel, externalModelBefore)
        XCTAssertEqual(backendManager.stopPolishingCallCount, 1)
        // Polishing disabled: stop only, no eager relaunch.
        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
    }

    func testManagedPolishingModelChangeRestartsEngineEagerly() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.applyLLMPolishingModelChange("example/new-polishing-model")
        await viewModel.polishingShutdownTask?.value
        await viewModel.polishingWarmupTask?.value

        // Field regression (PR #99 hand-test): picking a model must download
        // and relaunch immediately, not wait for a disable/enable toggle.
        XCTAssertEqual(backendManager.stopPolishingCallCount, 1)
        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: false, polishing: true)])
    }

    func testSpeechdCacheLimitChangeRestartsDictationEngineEagerly() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.applySpeechdCacheLimitChange(.gb2)
        await viewModel.dictationShutdownTask?.value
        await viewModel.dictationWarmupTask?.value

        // Owner rule (2026-07-17): changing the memory limit or step interval
        // must not require a Managed -> External -> Managed round trip.
        XCTAssertEqual(viewModel.settings.speechdCacheLimit, .gb2)
        XCTAssertEqual(backendManager.stopDictationCallCount, 1)
        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: true, polishing: false)])
    }

    func testSpeechdStepCadenceChangeRestartsDictationEngineEagerly() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.applySpeechdStepCadenceChange(.ms100)
        await viewModel.dictationShutdownTask?.value
        await viewModel.dictationWarmupTask?.value

        XCTAssertEqual(viewModel.settings.speechdStepCadence, .ms100)
        XCTAssertEqual(backendManager.stopDictationCallCount, 1)
        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: true, polishing: false)])
    }

    func testSpeechdSettingChangeOutsideManagedModePersistsWithoutRestart() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .externalURL
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.applySpeechdCacheLimitChange(.gb2)
        viewModel.applySpeechdStepCadenceChange(.ms100)

        XCTAssertNil(viewModel.dictationShutdownTask)
        XCTAssertEqual(viewModel.settings.speechdCacheLimit, .gb2)
        XCTAssertEqual(viewModel.settings.speechdStepCadence, .ms100)
        XCTAssertEqual(backendManager.stopDictationCallCount, 0)
        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
    }

    func testSpeechdSettingChangeToSameValueIsNoOp() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.applySpeechdCacheLimitChange(viewModel.settings.speechdCacheLimit)
        viewModel.applySpeechdStepCadenceChange(viewModel.settings.speechdStepCadence)

        XCTAssertNil(viewModel.dictationShutdownTask)
        XCTAssertEqual(backendManager.stopDictationCallCount, 0)
        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
    }

    func testDictationModeSwitchToManagedStartsDictationWarmup() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .externalURL
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.applyDictationBackendModeChange(.managedLocal)
        await viewModel.dictationWarmupTask?.value

        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: true, polishing: false)])
        XCTAssertEqual(backendManager.stopDictationCallCount, 0)
        XCTAssertEqual(backendManager.stopPolishingCallCount, 0)
        XCTAssertEqual(backendManager.stopAllCallCount, 0)
    }

    func testLLMPolishingDisabledDoesNotCancelInFlightDictationWarmup() async {
        let backendManager = FakeManagedBackendManager()
        backendManager.suspendEnsure = true
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .externalURL
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.applyDictationBackendModeChange(.managedLocal)
        await backendManager.waitUntilEnsureStarted()

        // Turning polishing off must stop polishd only — the speechd warmup keeps
        // its own task slot and must survive (regression: a shared slot let this
        // cancel the in-flight dictation warmup).
        viewModel.llmPolishingEnabledDidChange(false)
        await viewModel.polishingShutdownTask?.value

        XCTAssertEqual(viewModel.dictationWarmupTask?.isCancelled, false)
        backendManager.resumeEnsure()
        await viewModel.dictationWarmupTask?.value

        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: true, polishing: false)])
        XCTAssertEqual(backendManager.stopPolishingCallCount, 1)
        XCTAssertEqual(backendManager.stopDictationCallCount, 0)
    }

    func testDictationModeFlipBackToManagedSerializesWarmupBehindPendingStop() async {
        let backendManager = FakeManagedBackendManager()
        backendManager.suspendStopDictation = true
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.applyDictationBackendModeChange(.externalURL)
        await backendManager.waitForStopDictationCallCount(1)

        // Flip back while the stop is still executing: the warmup must wait for
        // the stop to finish, or the stale stop kills the fresh speechd process
        // (review finding on rapid managed→external→managed flips).
        viewModel.applyDictationBackendModeChange(.managedLocal)
        await Task.yield()
        XCTAssertTrue(backendManager.ensureCalls.isEmpty)

        backendManager.resumeStopDictation()
        await viewModel.dictationWarmupTask?.value

        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: true, polishing: false)])
        XCTAssertEqual(backendManager.stopDictationCallCount, 1)
    }

    // MARK: - Overlay Buffer reachability gating (polishing warmup follows triggers)

    /// Shortcuts mode with no Overlay Buffer shortcut and the menu-bar output
    /// mode on Live Auto-Paste: no trigger can start an Overlay Buffer session,
    /// so enabling polishing must not start managed polishd.
    func testPolishingEnableSkipsWarmupWhenOverlayBufferUnreachable() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .liveAutoPaste, backendManager: backendManager)
        viewModel.settings.modifierOnlyHotKeyEnabled = false
        viewModel.settings.setOverlayBufferShortcut(nil)
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.llmPolishingEnabledDidChange(true)
        await backendManager.waitForStopPolishingCallCount(1)

        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
        XCTAssertEqual(backendManager.stopPolishingCallCount, 1)
    }

    func testLaunchWarmupSkipsPolishingWhenOverlayBufferUnreachable() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .liveAutoPaste, backendManager: backendManager)
        viewModel.settings.modifierOnlyHotKeyEnabled = false
        viewModel.settings.setOverlayBufferShortcut(nil)
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.warmUpManagedBackendsAtLaunchIfNeeded()
        await viewModel.polishingWarmupTask?.value
        await Task.yield()

        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
    }

    /// With the single-modifier gesture active, tap always starts an Overlay
    /// Buffer session, so switching the menu-bar output mode to Live Auto-Paste
    /// must keep managed polishd running (regression: the old check stopped it).
    func testOutputModeSwitchToLiveKeepsPolishingWhenGestureConfigured() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.modifierOnlyHotKeyEnabled = true
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.applyDictationOutputModeChange(.liveAutoPaste)
        await Task.yield()

        XCTAssertEqual(backendManager.stopPolishingCallCount, 0)
    }

    /// Exact field repro (2026-07-06): shortcuts mode, menu-bar output mode
    /// still on Overlay Buffer, user clears the Overlay Buffer shortcut —
    /// polishing must become unavailable and managed polishd must stop. The
    /// menu-bar output mode does not count as a trigger.
    func testClearingOverlayShortcutStopsManagedPolishing() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.modifierOnlyHotKeyEnabled = false
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.updateOverlayBufferShortcut(nil)
        await backendManager.waitForStopPolishingCallCount(1)

        XCTAssertEqual(backendManager.stopPolishingCallCount, 1)
        XCTAssertFalse(viewModel.settings.isOverlayBufferSessionReachable)
    }

    func testReachabilityTransitionToReachableStartsPolishingWarmup() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .liveAutoPaste, backendManager: backendManager)
        viewModel.settings.modifierOnlyHotKeyEnabled = false
        viewModel.settings.setOverlayBufferShortcut(nil)
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        // The trigger picker switching to the single-modifier gesture makes
        // overlay sessions reachable again (wired via
        // applyDictationTriggerModeChange, which registers real hotkeys, so the
        // transition handler is driven directly here).
        viewModel.settings.modifierOnlyHotKeyEnabled = true
        viewModel.handleOverlayReachabilityTransition(wasReachable: false)
        await viewModel.polishingWarmupTask?.value

        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: false, polishing: true)])
        XCTAssertEqual(backendManager.stopPolishingCallCount, 0)
    }

    func testPolishingToggleOffThenOnCancelsQueuedStop() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        // Off then immediately on: the queued stop must never run, or it lands
        // after the warmup and stops the polishd the settings now require.
        viewModel.llmPolishingEnabledDidChange(false)
        viewModel.llmPolishingEnabledDidChange(true)
        await viewModel.polishingWarmupTask?.value

        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: false, polishing: true)])
        XCTAssertEqual(backendManager.stopPolishingCallCount, 0)
    }

    func testPolishingModeSwitchToManagedStartsPolishingWarmupWhenRequired() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.applyPolishingBackendModeChange(.managedLocal)
        await viewModel.polishingWarmupTask?.value

        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: false, polishing: true)])
        XCTAssertEqual(backendManager.stopPolishingCallCount, 0)
    }

    func testPolishingModeSwitchToManagedDoesNotWarmUpWhenPolishingUnavailable() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .liveAutoPaste, backendManager: backendManager)
        viewModel.settings.setOverlayBufferShortcut(nil)
        viewModel.settings.modifierOnlyHotKeyEnabled = false
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.applyPolishingBackendModeChange(.managedLocal)
        await viewModel.polishingWarmupTask?.value

        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
        XCTAssertNil(viewModel.polishingWarmupTask)
    }

    // MARK: - LLM polishing enable toggle stops managed polishd

    func testLLMPolishingDisabledInManagedModeStopsPolishing() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.polishingBackendMode = .managedLocal
        retainForTestProcessLifetime(viewModel)

        viewModel.llmPolishingEnabledDidChange(false)
        // The shutdown runs in a tracked task; await it deterministically
        // rather than racing on Task.yield().
        await viewModel.polishingShutdownTask?.value

        XCTAssertEqual(backendManager.stopPolishingCallCount, 1)
    }

    func testLLMPolishingDisabledInExternalModeDoesNotStopPolishing() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.polishingBackendMode = .externalURL
        retainForTestProcessLifetime(viewModel)

        viewModel.llmPolishingEnabledDidChange(false)
        await viewModel.polishingShutdownTask?.value

        XCTAssertEqual(backendManager.stopPolishingCallCount, 0)
        XCTAssertNil(viewModel.polishingShutdownTask)
    }

    func testLLMPolishingEnabledInManagedModeWarmsUpPolishingEagerly() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.llmPolishingEnabledDidChange(true)
        await viewModel.polishingWarmupTask?.value

        // Owner-specified UX: enabling the toggle immediately bootstraps the
        // managed polishing backend (install/model download/start) so the
        // inline Settings progress has something to show — it must not wait
        // for the next dictation.
        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: false, polishing: true)])
        XCTAssertEqual(backendManager.stopPolishingCallCount, 0)
        XCTAssertNil(viewModel.polishingShutdownTask)
    }

    func testLLMPolishingEnabledInExternalModeDoesNotWarmUp() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.llmPolishingEnabledDidChange(true)
        await viewModel.polishingWarmupTask?.value

        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
        XCTAssertNil(viewModel.polishingWarmupTask)
    }

    func testLLMPolishingDisabledCancelsInFlightWarmup() async {
        let backendManager = FakeManagedBackendManager()
        backendManager.suspendEnsure = true
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.llmPolishingEnabledDidChange(true)
        await backendManager.waitUntilEnsureStarted()
        let warmup = viewModel.polishingWarmupTask

        viewModel.llmPolishingEnabledDidChange(false)
        backendManager.resumeEnsure()
        await warmup?.value
        await viewModel.polishingShutdownTask?.value

        XCTAssertTrue(warmup?.isCancelled == true)
        XCTAssertEqual(backendManager.stopPolishingCallCount, 1)
    }

    /// The menu-bar output mode is not a reachability input: switching it in
    /// either direction must never start or stop managed polishd.
    func testDictationOutputModeSwitchesNeverTouchManagedPolishing() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.setOverlayBufferShortcut(nil)
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.applyDictationOutputModeChange(.liveAutoPaste)
        await Task.yield()
        viewModel.applyDictationOutputModeChange(.overlayBuffer)
        await Task.yield()

        XCTAssertEqual(viewModel.settings.dictationOutputMode, .overlayBuffer)
        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
        XCTAssertEqual(backendManager.stopPolishingCallCount, 0)
    }

    func testWarmUpManagedBackendsAtLaunchIfNeededManagedDictationAndPolishingRequestsBoth() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.warmUpManagedBackendsAtLaunchIfNeeded()
        await viewModel.dictationWarmupTask?.value
        await viewModel.polishingWarmupTask?.value

        // Per-backend warmup slots: two independent ensure requests, one per
        // backend, so neither can cancel the other later.
        XCTAssertEqual(backendManager.ensureCalls.count, 2)
        XCTAssertTrue(backendManager.ensureCalls.contains(.init(dictation: true, polishing: false)))
        XCTAssertTrue(backendManager.ensureCalls.contains(.init(dictation: false, polishing: true)))
        XCTAssertEqual(backendManager.stopPolishingCallCount, 0)
    }

    func testWarmUpManagedBackendsAtLaunchIfNeededManagedDictationOnlyRequestsDictationOnly() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .liveAutoPaste, backendManager: backendManager)
        // Polishing is enabled but unreachable (no gesture, no overlay
        // shortcut, Live output mode), so launch must warm dictation only.
        viewModel.settings.modifierOnlyHotKeyEnabled = false
        viewModel.settings.setOverlayBufferShortcut(nil)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.warmUpManagedBackendsAtLaunchIfNeeded()
        await viewModel.dictationWarmupTask?.value

        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: true, polishing: false)])
        XCTAssertNil(viewModel.polishingWarmupTask)
    }

    func testWarmUpManagedBackendsAtLaunchIfNeededOnboardingIncompleteDoesNotWarmUp() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = false
        retainForTestProcessLifetime(viewModel)

        viewModel.warmUpManagedBackendsAtLaunchIfNeeded()
        await viewModel.polishingWarmupTask?.value

        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
        XCTAssertNil(viewModel.dictationWarmupTask)
        XCTAssertNil(viewModel.polishingWarmupTask)
    }

    func testWarmUpManagedBackendsAtLaunchIfNeededExternalModesDoNotWarmUp() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .externalURL
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.warmUpManagedBackendsAtLaunchIfNeeded()
        await viewModel.polishingWarmupTask?.value

        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
        XCTAssertNil(viewModel.dictationWarmupTask)
        XCTAssertNil(viewModel.polishingWarmupTask)
    }

    func testWarmUpManagedBackendsAtLaunchIfNeededEnabledManagedWarmsUpPolishingOnly() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.warmUpManagedBackendsAtLaunchIfNeeded()
        await viewModel.polishingWarmupTask?.value

        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: false, polishing: true)])
        XCTAssertEqual(backendManager.stopPolishingCallCount, 0)
    }

    func testWarmUpManagedBackendsAtLaunchIfNeededDisabledDoesNotWarmUp() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = false
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.warmUpManagedBackendsAtLaunchIfNeeded()
        await viewModel.polishingWarmupTask?.value

        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
        XCTAssertNil(viewModel.polishingWarmupTask)
    }

    /// Live menu-bar output mode with the Overlay Buffer shortcut still
    /// configured: overlay sessions stay one keystroke away, so launch warms
    /// polishing anyway (the old output-mode-only check skipped it and the
    /// first overlay dictation paid the cold start).
    func testWarmUpManagedBackendsAtLaunchIfNeededLiveOutputModeWarmsPolishingWhenOverlayShortcutConfigured() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .liveAutoPaste, backendManager: backendManager)
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.warmUpManagedBackendsAtLaunchIfNeeded()
        await viewModel.polishingWarmupTask?.value

        XCTAssertEqual(backendManager.ensureCalls, [.init(dictation: false, polishing: true)])
    }

    func testWarmUpManagedBackendsAtLaunchIfNeededExternalPolishingModeDoesNotWarmUpPolishing() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        viewModel.warmUpManagedBackendsAtLaunchIfNeeded()
        await viewModel.polishingWarmupTask?.value

        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
        XCTAssertNil(viewModel.polishingWarmupTask)
    }

    // MARK: - Menu bar backend readiness indicator

    func testMenuBarIndicatorShowsFailureWhenManagedDictationBackendIsNotReady() {
        let backendManager = FakeManagedBackendManager()
        backendManager.speechdStatus = .starting
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        XCTAssertFalse(viewModel.requiredManagedBackendsReady)
        XCTAssertEqual(viewModel.menuBarIndicatorState, .failure)
    }

    func testMenuBarIndicatorShowsIdleWhenRequiredManagedBackendsAreReady() {
        let backendManager = FakeManagedBackendManager()
        backendManager.speechdStatus = .ready
        backendManager.polishdStatus = .ready
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        XCTAssertTrue(viewModel.requiredManagedBackendsReady)
        XCTAssertEqual(viewModel.menuBarIndicatorState, .idle)
    }

    func testMenuBarIndicatorShowsIdleForExternalModesEvenWhenManagedBackendsAreStopped() {
        let backendManager = FakeManagedBackendManager()
        backendManager.speechdStatus = .stopped
        backendManager.polishdStatus = .failed(summary: "mlx-lm failed to start.", detail: "trace")
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .externalURL
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        XCTAssertTrue(viewModel.requiredManagedBackendsReady)
        XCTAssertEqual(viewModel.menuBarIndicatorState, .idle)
    }

    func testMenuBarIndicatorShowsFailureWhenRequiredManagedPolishingBackendFailed() {
        let backendManager = FakeManagedBackendManager()
        backendManager.speechdStatus = .ready
        backendManager.polishdStatus = .failed(summary: "mlx-lm failed to start.", detail: "trace")
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .externalURL
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = true
        retainForTestProcessLifetime(viewModel)

        XCTAssertFalse(viewModel.requiredManagedBackendsReady)
        XCTAssertEqual(viewModel.menuBarIndicatorState, .failure)
    }

    func testMenuBarIndicatorIgnoresManagedBackendReadinessUntilOnboardingCompletes() {
        let backendManager = FakeManagedBackendManager()
        backendManager.speechdStatus = .stopped
        backendManager.polishdStatus = .stopped
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.polishingBackendMode = .managedLocal
        viewModel.settings.llmPolishingEnabled = true
        viewModel.settings.onboardingCompleted = false
        retainForTestProcessLifetime(viewModel)

        XCTAssertTrue(viewModel.requiredManagedBackendsReady)
        XCTAssertEqual(viewModel.menuBarIndicatorState, .idle)
    }

    func testMenuBarIndicatorSessionConnectedWinsOverUnreadyManagedBackend() {
        let backendManager = FakeManagedBackendManager()
        backendManager.speechdStatus = .starting
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.onboardingCompleted = true
        viewModel.realtimeSessionIndicatorState = .connected
        retainForTestProcessLifetime(viewModel)

        XCTAssertFalse(viewModel.requiredManagedBackendsReady)
        XCTAssertEqual(viewModel.menuBarIndicatorState, .connected)
    }

    func testMenuBarIndicatorRecentFailureWinsOverReadyManagedBackends() {
        let backendManager = FakeManagedBackendManager()
        backendManager.speechdStatus = .ready
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.settings.onboardingCompleted = true
        viewModel.realtimeSessionIndicatorState = .recentFailure
        retainForTestProcessLifetime(viewModel)

        XCTAssertTrue(viewModel.requiredManagedBackendsReady)
        XCTAssertEqual(viewModel.menuBarIndicatorState, .failure)
    }

    func testReRunOnboardingResetsFlagAndInvokesPresenter() {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.onboardingCompleted = true
        var presentations = 0
        viewModel.onRequestReRunOnboarding = { presentations += 1 }
        retainForTestProcessLifetime(viewModel)

        viewModel.reRunOnboarding()

        XCTAssertFalse(viewModel.settings.onboardingCompleted)
        XCTAssertEqual(presentations, 1)
    }

    // MARK: - Helpers

    func testLiveStartUnderSecureInputRefusesBeforeManagedBackendStartup() {
        // Codex finding on #90 (round 3): the refusal used to run only inside
        // beginDictationSession, AFTER ensureReady — a cold managed backend
        // would start a lengthy install/download for a doomed live session.
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.apple.Terminal" }
        TerminalTargetDetector.debugSecureEventInputOverride = { true }
        addTeardownBlock {
            TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
            TerminalTargetDetector.debugSecureEventInputOverride = nil
        }

        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .liveAutoPaste, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.secureInputWarningSound = {}

        viewModel.beginDictationAfterManagedBackendIfNeeded()

        XCTAssertTrue(
            backendManager.ensureCalls.isEmpty,
            "no backend boot for a session that will be refused"
        )
        XCTAssertEqual(
            viewModel.statusText,
            DictationViewModel.StatusStrings.liveDictationBlockedBySecureInput
        )
        XCTAssertEqual(viewModel.menuBarIndicatorState, .secureInputWarning)
        XCTAssertFalse(viewModel.isConnectingRealtimeSession)
    }

    func testDelayedSecureInputRefusalAfterManagedStartupDoesNotWedgeTheIcon() async {
        // Codex finding on #90 (round 8): secure input can turn ON while a
        // managed backend boots. The refusal then fires from the startup
        // task — after the initiating tap already ended — and no gesture-end
        // event remains, so the red icon and "Blocked" status wedged until
        // the next interaction. The startup path now ends the refusal
        // signals itself when no gesture is still held.
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.apple.Terminal" }
        TerminalTargetDetector.debugSecureEventInputOverride = { false } // off at press
        addTeardownBlock {
            TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
            TerminalTargetDetector.debugSecureEventInputOverride = nil
        }

        let backendManager = FakeManagedBackendManager()
        backendManager.suspendEnsure = true
        let viewModel = makeViewModel(outputMode: .liveAutoPaste, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.debugMicrophoneAuthorizationStatusOverride = .authorized
        var soundPlays = 0
        viewModel.secureInputWarningSound = { soundPlays += 1 }
        retainForTestProcessLifetime(viewModel)

        viewModel.beginDictationAfterManagedBackendIfNeeded()
        await backendManager.waitUntilEnsureStarted()
        XCTAssertTrue(viewModel.isConnectingRealtimeSession, "preflight passed; backend boot in flight")

        // The user focuses a password field while the backend boots; the
        // initiating gesture is long over by the time startup completes.
        TerminalTargetDetector.debugSecureEventInputOverride = { true }
        backendManager.resumeEnsure()
        await viewModel.managedStartupTask?.value

        XCTAssertFalse(viewModel.isDictating, "the doomed live session is still refused")
        XCTAssertEqual(soundPlays, 1, "the audible refusal cue fired")
        XCTAssertEqual(
            viewModel.lastError,
            DictationViewModel.secureKeyboardEntryWarningMessage,
            "the popover keeps the explanation"
        )
        XCTAssertNotEqual(
            viewModel.menuBarIndicatorState, .secureInputWarning,
            "no gesture-end event will ever come — the icon must not wedge"
        )
        XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.ready)
    }

    func testDelayedSecureInputRefusalAfterMicPermissionGrantDoesNotWedgeTheIcon() async {
        // Codex finding on #90 (round 9): same wedge as the managed-startup
        // one (round 8) via the OTHER async continuation — the microphone
        // permission dialog. A toggle tap starts with permission
        // undetermined; secure input turns on while the dialog is up; the
        // grant continuation re-enters the managed-backend entry point,
        // which refuses with no gesture-end event left to clear the signals.
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.apple.Terminal" }
        TerminalTargetDetector.debugSecureEventInputOverride = { false } // off at press
        addTeardownBlock {
            TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
            TerminalTargetDetector.debugSecureEventInputOverride = nil
        }

        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .liveAutoPaste, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .managedLocal
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.debugMicrophoneAuthorizationStatusOverride = .notDetermined
        var permissionCompletion: (@Sendable (Bool) -> Void)?
        viewModel.debugMicrophoneRequestAccessOverride = { permissionCompletion = $0 }
        var soundPlays = 0
        viewModel.secureInputWarningSound = { soundPlays += 1 }
        retainForTestProcessLifetime(viewModel)

        // Toggle tap: the secure-input preflight passes, the mic gate parks
        // the start behind the permission dialog, and the tap gesture ends.
        viewModel.startDictation()
        XCTAssertTrue(viewModel.isAwaitingMicrophonePermission)
        guard let grantPermission = permissionCompletion else {
            return XCTFail("the permission request must route through the test seam")
        }

        // Secure input turns on while the dialog is up; then the user grants.
        TerminalTargetDetector.debugSecureEventInputOverride = { true }
        grantPermission(true)
        // The continuation hops to the main actor and runs synchronously to
        // completion once started; drain the hop without wall-clock waits.
        var spins = 0
        while viewModel.isAwaitingMicrophonePermission, spins < 1_000 {
            spins += 1
            await Task.yield()
        }

        XCTAssertFalse(viewModel.isDictating, "the doomed live session is still refused")
        XCTAssertTrue(backendManager.ensureCalls.isEmpty, "still no backend boot for a refused start")
        XCTAssertEqual(soundPlays, 1, "the audible refusal cue fired")
        XCTAssertEqual(
            viewModel.lastError,
            DictationViewModel.secureKeyboardEntryWarningMessage,
            "the popover keeps the explanation"
        )
        XCTAssertNotEqual(
            viewModel.menuBarIndicatorState, .secureInputWarning,
            "no gesture-end event will ever come — the icon must not wedge"
        )
        XCTAssertEqual(viewModel.statusText, DictationViewModel.StatusStrings.ready)
    }

    private func makeViewModel(
        outputMode: DictationOutputMode,
        backendManager: (any ManagedBackendManaging)? = nil
    ) -> DictationViewModel {
        let settings = makeSettings(outputMode: outputMode)
        let viewModel = DictationViewModel(
            settings: settings,
            backendManager: backendManager,
            overlayBufferCoordinator: NoopOverlayCoordinator(),
            startRuntimeServices: false
        )
        // Keep tests hermetic: session start reads config (terminal apps,
        // replacement dictionary) through the store — never the real
        // config directory.
        viewModel.appConfigStore = FailFastHermeticConfigStore()
        return viewModel
    }

    private func makeSettings(outputMode: DictationOutputMode) -> SettingsStore {
        let suiteName = "localvoxtral.DictationViewModelFailFastUXTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(defaults: defaults, environment: [:])
        // These tests exercise connection-failure UX against a user-configured
        // external endpoint (a closed port). Pin external mode so that the
        // configured realtimeAPIEndpointURL is honored rather than overridden
        // by the managed-local default.
        settings.dictationBackendMode = .externalURL
        settings.polishingBackendMode = .externalURL
        settings.dictationOutputMode = outputMode
        return settings
    }

    /// Emits a fake backend status and suspends until the view model's
    /// managed-startup status mirror has processed it. A bare `Task.yield()`
    /// after `emitStatus` is a scheduling race: the mirror's `for await` loop
    /// may not have run yet when the test asserts on `statusText` (flaked on
    /// main, CI run 28752686491).
    private func emitStatusAndAwaitMirror(
        _ backendManager: FakeManagedBackendManager,
        viewModel: DictationViewModel,
        spec: ManagedBackendSpec,
        status: ManagedBackendStatus
    ) async {
        await withCheckedContinuation { continuation in
            viewModel.debugManagedStatusMirrorEventSink = {
                viewModel.debugManagedStatusMirrorEventSink = nil
                continuation.resume()
            }
            backendManager.emitStatus(spec: spec, status: status)
        }
    }

    private func retainForTestProcessLifetime(_ viewModel: DictationViewModel) {
        Self.retainedViewModels.append(viewModel)
    }

    private static func formattedTimeout(_ timeout: TimeInterval) -> String {
        let seconds = max(1, Int(timeout.rounded()))
        return "\(seconds) \(seconds == 1 ? "second" : "seconds")"
    }
}

// MARK: - Test-only accessors and doubles

private final class FailFastHermeticConfigStore: AppConfigServing {
    func configDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
    }

    func loadReplacementDictionary() -> ReplacementDictionary {
        ReplacementDictionary(entries: [])
    }

    func loadLLMPromptTemplates() -> LLMPromptTemplates {
        LLMPromptTemplates(systemContent: "system", userContent: "{{input_text}}")
    }

    func loadTerminalAppBundleIDs() -> [String] {
        []
    }
}

@MainActor
private final class NoopOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitTargetAppPID: pid_t? = nil

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(targetRect: .zero, source: .windowCenter)
    }
    func startSession(preResolvedAnchor: OverlayAnchor?) {}
    func beginFinalizing(displayBufferText: String, commitBufferText: String) {}
    func refresh(displayBufferText: String, commitBufferText: String) {}
    @discardableResult
    func commitIfNeeded(using textCommitter: OverlayTextCommitting, autoCopyEnabled: Bool) -> OverlayBufferCommitOutcome {
        .succeeded
    }
    func dismissAfterHold(minimumVisibility: TimeInterval) {}
    func reset() {}
    func captureLiveCommitTargetAppPID() {}
}

@MainActor
private final class FakeManagedBackendManager: ManagedBackendManaging {
    struct EnsureCall: Equatable {
        var dictation: Bool
        var polishing: Bool
    }

    var speechdStatus: ManagedBackendStatus = .stopped
    var polishdStatus: ManagedBackendStatus = .stopped
    private var statusUpdateContinuations: [UUID: AsyncStream<ManagedBackendStatusUpdate>.Continuation] = [:]
    var statusUpdates: AsyncStream<ManagedBackendStatusUpdate> {
        let id = UUID()
        let stream = AsyncStream<ManagedBackendStatusUpdate>.makeStream(of: ManagedBackendStatusUpdate.self)
        statusUpdateContinuations[id] = stream.continuation
        stream.continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.statusUpdateContinuations[id] = nil
            }
        }
        return stream.stream
    }
    var ensureError: Error?
    var suspendEnsure = false
    var suspendStopDictation = false
    private(set) var ensureCalls: [EnsureCall] = []
    private(set) var stopAllCallCount = 0
    private(set) var stopDictationCallCount = 0
    private(set) var stopPolishingCallCount = 0
    private var ensureStartedContinuation: CheckedContinuation<Void, Never>?
    private var ensureResumeContinuation: CheckedContinuation<Void, Never>?
    private var stopDictationContinuation: CheckedContinuation<Void, Never>?
    private var stopDictationResumeContinuation: CheckedContinuation<Void, Never>?
    private var stopPolishingContinuation: CheckedContinuation<Void, Never>?

    func ensureReady(dictation: Bool, polishing: Bool) async throws {
        ensureCalls.append(.init(dictation: dictation, polishing: polishing))
        ensureStartedContinuation?.resume()
        ensureStartedContinuation = nil

        if suspendEnsure {
            await withCheckedContinuation { continuation in
                ensureResumeContinuation = continuation
            }
        }

        if let ensureError {
            throw ensureError
        }

        if dictation {
            emitStatus(spec: BackendCatalog.speechd, status: .ready)
        }
        if polishing {
            emitStatus(spec: BackendCatalog.polishd, status: .ready)
        }
    }

    func stopAll() async {
        stopAllCallCount += 1
    }

    func stopDictation() async {
        stopDictationCallCount += 1
        stopDictationContinuation?.resume()
        stopDictationContinuation = nil

        if suspendStopDictation {
            await withCheckedContinuation { continuation in
                stopDictationResumeContinuation = continuation
            }
        }
    }

    func stopPolishing() async {
        stopPolishingCallCount += 1
        stopPolishingContinuation?.resume()
        stopPolishingContinuation = nil
    }

    func recentOutput(for spec: ManagedBackendSpec) -> [String] {
        []
    }

    func emitStatus(spec: ManagedBackendSpec, status: ManagedBackendStatus) {
        switch spec.id {
        case BackendCatalog.speechd.id:
            speechdStatus = status
        case BackendCatalog.polishd.id:
            polishdStatus = status
        default:
            break
        }
        let update = ManagedBackendStatusUpdate(spec: spec, status: status)
        for continuation in statusUpdateContinuations.values {
            continuation.yield(update)
        }
    }

    func waitUntilEnsureStarted() async {
        guard ensureCalls.isEmpty else { return }
        await withCheckedContinuation { continuation in
            ensureStartedContinuation = continuation
        }
    }

    func resumeEnsure() {
        ensureResumeContinuation?.resume()
        ensureResumeContinuation = nil
    }

    func resumeStopDictation() {
        stopDictationResumeContinuation?.resume()
        stopDictationResumeContinuation = nil
    }

    func waitForStopDictationCallCount(_ expected: Int) async {
        guard stopDictationCallCount < expected else { return }
        await withCheckedContinuation { continuation in
            stopDictationContinuation = continuation
        }
    }

    func waitForStopPolishingCallCount(_ expected: Int) async {
        guard stopPolishingCallCount < expected else { return }
        await withCheckedContinuation { continuation in
            stopPolishingContinuation = continuation
        }
    }
}

private struct FakeManagedBackendFailure: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

extension DictationViewModel {
    /// Test-only access to the sanitized endpoint used in user-facing messages.
    @MainActor
    fileprivate func sanitizedRealtimeEndpointForMessageReference() -> String {
        // Mirrors the private sanitizedRealtimeEndpointForMessage() for assertions.
        let endpoint = settings.resolvedWebSocketURL(for: settings.realtimeProvider)
        guard let endpoint else { return "<invalid endpoint>" }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint.absoluteString
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? endpoint.absoluteString
    }
}
