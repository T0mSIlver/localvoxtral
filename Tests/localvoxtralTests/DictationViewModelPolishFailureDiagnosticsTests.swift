import Foundation
import XCTest
@testable import localvoxtral

/// Connection-failure diagnostics for LLM polishing must name the endpoint the
/// failing request was ACTUALLY sent to. Field regression (2026-07-11): in
/// managed mode (polishd on 127.0.0.1:8472) a timeout was reported against the
/// external-URL setting's untouched placeholder default (127.0.0.1:8080),
/// sending debugging to a process that was never involved.
@MainActor
final class DictationViewModelPolishFailureDiagnosticsTests: XCTestCase {
    // DictationViewModel owns app-lifetime services; retain test instances for
    // the process lifetime (mirrors the token-guard suite).
    private static var retainedViewModels: [DictationViewModel] = []

    /// Managed mode + a polish request that fails with a network error: the
    /// surfaced failure details must name the managed polishd endpoint (the
    /// one the request went to), never the external-URL setting.
    func testManagedModeFailureNamesManagedEndpointNotExternalSetting() async throws {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        settings.polishingBackendMode = .managedLocal
        // The external-URL setting keeps its placeholder default (:8080). In
        // managed mode it plays no part in the request.
        XCTAssertTrue(settings.llmPolishingEndpointURL.contains("8080"))

        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        viewModel.llmPolishingService = TimeoutFailingPolishingService()
        // The failure path presents a REAL modal NSAlert when NSApp exists —
        // the exact suite-hang class AGENTS.md warns about. Pre-setting the
        // alert flag makes presentConnectionFailureAlert a no-op (same
        // pattern as the sibling network-failure tests); lastError is still
        // set before the alert gate.
        viewModel.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        viewModel.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.currentDictationEventText = "polish this text"

        viewModel.finishStoppedSession(promotePendingSegment: false)
        await waitUntilStoppedSessionCompletes(viewModel)

        let lastError = try XCTUnwrap(viewModel.lastError)
        XCTAssertTrue(
            lastError.contains("127.0.0.1:8472"),
            "failure details must name the managed endpoint actually used: \(lastError)"
        )
        XCTAssertFalse(
            lastError.contains("8080"),
            "failure details must not name the unused external-URL setting: \(lastError)"
        )
    }

    /// The details formatter itself: the given endpoint URL (sanitized) is
    /// named both with and without underlying error details.
    func testConnectionTechnicalDetailsNameTheGivenEndpoint() {
        let settings = makeSettings(outputMode: .overlayBuffer)
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        retainForTestProcessLifetime(viewModel)
        let endpoint = URL(string: "http://127.0.0.1:8472/v1/chat/completions")!

        XCTAssertEqual(
            viewModel.llmPolishingConnectionTechnicalDetails(
                "request timed out", endpointURL: endpoint
            ),
            "request timed out [endpoint: http://127.0.0.1:8472/v1/chat/completions]"
        )
        XCTAssertEqual(
            viewModel.llmPolishingConnectionTechnicalDetails(
                "  ", endpointURL: endpoint
            ),
            "Unable to connect to endpoint http://127.0.0.1:8472/v1/chat/completions."
        )
    }

    // MARK: - Harness (mirrors the token-guard suite)

    private func waitUntilStoppedSessionCompletes(_ viewModel: DictationViewModel) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while viewModel.isCompletingStoppedSession, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeSettings(outputMode: DictationOutputMode) -> SettingsStore {
        let suiteName =
            "localvoxtral.DictationViewModelPolishFailureDiagnosticsTests.\(UUID().uuidString)"
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

/// Always fails like a client-side timeout, exercising the connection-failure
/// diagnostics path without networking.
private actor TimeoutFailingPolishingService: LLMPolishingServicing {
    func polish(
        request _: LLMPolishingRequest,
        configuration _: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        throw LLMPolishingError.networkError("The request timed out.")
    }
}

private final class MockAppConfigStore: AppConfigServing {
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
private final class MockOverlayCoordinator: OverlayBufferSessionCoordinating {
    var commitTargetAppPID: pid_t? = nil

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(
            targetRect: CGRect(x: 0, y: 0, width: 100, height: 24),
            source: .windowCenter
        )
    }

    func startSession(preResolvedAnchor _: OverlayAnchor?) {}
    func beginFinalizing(displayBufferText _: String, commitBufferText _: String) {}
    func refresh(displayBufferText _: String, commitBufferText _: String) {}

    func commitIfNeeded(
        using _: OverlayTextCommitting,
        autoCopyEnabled _: Bool
    ) -> OverlayBufferCommitOutcome {
        .succeeded
    }

    func dismissAfterHold(minimumVisibility _: TimeInterval) {}
    func reset() {}
    func captureLiveCommitTargetAppPID() {}
}
