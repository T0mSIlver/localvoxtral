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
                "No connection response received in \(Int(TimingConstants.connectTimeout)) seconds"
            ) == true
        )
        XCTAssertTrue(viewModel.lastError?.contains(endpoint) == true)
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
        viewModel.activeClientSource = .realtimeAPI
        viewModel.isConnectingRealtimeSession = true

        viewModel.handle(event: .disconnected, source: .realtimeAPI)

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

    // MARK: - Helpers

    private func makeViewModel(outputMode: DictationOutputMode) -> DictationViewModel {
        let settings = makeSettings(outputMode: outputMode)
        let viewModel = DictationViewModel(
            settings: settings,
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
        settings.dictationOutputMode = outputMode
        return settings
    }

    private func retainForTestProcessLifetime(_ viewModel: DictationViewModel) {
        Self.retainedViewModels.append(viewModel)
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
