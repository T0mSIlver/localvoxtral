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

    func testBeginDictationSessionSurfacesAccessibilityWarningInLiveMode() {
        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        // Point at a closed port so the async connect fails fast and does not
        // hit a real backend. The AX warning is asserted synchronously, before
        // any connect result can race back.
        viewModel.settings.realtimeAPIEndpointURL = "ws://127.0.0.1:65535/realtime"
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.textInsertion.debugSetAccessibilityTrusted(false)
        retainForTestProcessLifetime(viewModel)

        viewModel.beginDictationSession()

        // Fail-fast warning surfaces at start and is not clobbered by the
        // generic "Connecting..." status.
        XCTAssertEqual(viewModel.statusText, "Paste blocked by Accessibility permission.")
        XCTAssertEqual(viewModel.lastError, DictationViewModel.liveAutoPasteAccessibilityWarningMessage)
        XCTAssertTrue(viewModel.isConnectingRealtimeSession, "session still proceeds so AX can be granted mid-session")

        viewModel.abortConnectingSession()
    }

    func testBeginDictationSessionSkipsAccessibilityWarningWhenTrustedInLiveMode() {
        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        viewModel.settings.realtimeAPIEndpointURL = "ws://127.0.0.1:65535/realtime"
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.textInsertion.debugSetAccessibilityTrusted(true)
        retainForTestProcessLifetime(viewModel)

        viewModel.beginDictationSession()

        XCTAssertEqual(viewModel.statusText, "Connecting to realtime backend...")
        XCTAssertNil(viewModel.lastError)

        viewModel.abortConnectingSession()
    }

    func testBeginDictationSessionSkipsAccessibilityWarningInOverlayMode() {
        let viewModel = makeViewModel(outputMode: .overlayBuffer)
        viewModel.settings.realtimeAPIEndpointURL = "ws://127.0.0.1:65535/realtime"
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.textInsertion.debugSetAccessibilityTrusted(false)
        retainForTestProcessLifetime(viewModel)

        viewModel.beginDictationSession()

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
        backendManager.ensureError = FakeManagedBackendFailure(message: "voxmlx failed: missing wheel")
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
        XCTAssertEqual(viewModel.statusText, "Installing dictation backend...")
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

        backendManager.emitStatus(
            spec: BackendCatalog.voxmlx,
            status: .preparingModel(progress: ModelDownloadProgress(downloadedBytes: 36, totalBytes: 100))
        )
        await Task.yield()

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

        backendManager.emitStatus(
            spec: BackendCatalog.mlxLM,
            status: .preparingModel(progress: ModelDownloadProgress(downloadedBytes: 1, totalBytes: 4))
        )
        await Task.yield()

        XCTAssertEqual(viewModel.statusText, "Downloading polishing model (25%)...")

        backendManager.ensureError = FakeManagedBackendFailure(message: "cancelled")
        backendManager.resumeEnsure()
        await viewModel.managedStartupTask?.value
    }

    func testStartDictationInExternalModeNeverTouchesManagedBackendManager() {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .externalURL
        viewModel.settings.polishingBackendMode = .externalURL
        viewModel.settings.realtimeAPIEndpointURL = ""
        viewModel.isShowingConnectionFailureAlert = true
        viewModel.debugMicrophoneAuthorizationStatusOverride = .authorized
        retainForTestProcessLifetime(viewModel)

        viewModel.startDictation()

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
        XCTAssertEqual(viewModel.statusText, "Installing polishing backend...")
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

    func testModeSwitchesToManagedStartNoBackends() async {
        let backendManager = FakeManagedBackendManager()
        let viewModel = makeViewModel(outputMode: .overlayBuffer, backendManager: backendManager)
        viewModel.settings.dictationBackendMode = .externalURL
        viewModel.settings.polishingBackendMode = .externalURL
        retainForTestProcessLifetime(viewModel)

        viewModel.applyDictationBackendModeChange(.managedLocal)
        viewModel.applyPolishingBackendModeChange(.managedLocal)
        await Task.yield()

        XCTAssertTrue(backendManager.ensureCalls.isEmpty)
        XCTAssertEqual(backendManager.stopDictationCallCount, 0)
        XCTAssertEqual(backendManager.stopPolishingCallCount, 0)
        XCTAssertEqual(backendManager.stopAllCallCount, 0)
    }

    // MARK: - LLM polishing enable toggle stops managed mlx-lm

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

    // MARK: - Helpers

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

    private func retainForTestProcessLifetime(_ viewModel: DictationViewModel) {
        Self.retainedViewModels.append(viewModel)
    }

    private static func formattedTimeout(_ timeout: TimeInterval) -> String {
        let seconds = max(1, Int(timeout.rounded()))
        return "\(seconds) \(seconds == 1 ? "second" : "seconds")"
    }
}

// MARK: - Test-only accessors and doubles

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

    var voxmlxStatus: ManagedBackendStatus = .notInstalled
    var mlxLMStatus: ManagedBackendStatus = .notInstalled
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
    private(set) var ensureCalls: [EnsureCall] = []
    private(set) var stopAllCallCount = 0
    private(set) var stopDictationCallCount = 0
    private(set) var stopPolishingCallCount = 0
    private var ensureStartedContinuation: CheckedContinuation<Void, Never>?
    private var ensureResumeContinuation: CheckedContinuation<Void, Never>?
    private var stopDictationContinuation: CheckedContinuation<Void, Never>?
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
            emitStatus(spec: BackendCatalog.voxmlx, status: .ready)
        }
        if polishing {
            emitStatus(spec: BackendCatalog.mlxLM, status: .ready)
        }
    }

    func stopAll() async {
        stopAllCallCount += 1
    }

    func stopDictation() async {
        stopDictationCallCount += 1
        stopDictationContinuation?.resume()
        stopDictationContinuation = nil
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
        case BackendCatalog.voxmlx.id:
            voxmlxStatus = status
        case BackendCatalog.mlxLM.id:
            mlxLMStatus = status
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
