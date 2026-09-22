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
        viewModel.llmPolishingService = FakePolishingService(
            failing: LLMPolishingError.networkError("The request timed out.")
        )
        // The failure path presents a REAL modal NSAlert when NSApp exists —
        // the exact suite-hang class AGENTS.md warns about. Pre-setting the
        // alert flag makes presentConnectionFailureAlert a no-op (same
        // pattern as the sibling network-failure tests); lastError is still
        // set before the alert gate.
        viewModel.session.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        viewModel.session.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.transcript.currentDictationEventText = "polish this text"

        viewModel.session.finishStoppedSession(promotePendingSegment: false)
        await awaitStoppedSessionCommit(viewModel)

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

    /// #314: a transport timeout means the endpoint was reachable and slow (a long
    /// transcript, a cold prefix cache). It keeps its own case; everything else stays a
    /// network error.
    func testTransportTimeoutIsClassifiedAsTimeoutNotNetworkError() {
        guard case .timedOut(let seconds) = LLMPolishingService.polishingError(
            forTransportError: URLError(.timedOut),
            timeoutSeconds: 40
        ) else {
            return XCTFail("a URLError timeout must classify as .timedOut")
        }
        XCTAssertEqual(seconds, 40)

        guard case .networkError = LLMPolishingService.polishingError(
            forTransportError: URLError(.cannotConnectToHost),
            timeoutSeconds: 40
        ) else {
            return XCTFail("a refused connection must stay a network error")
        }
    }

    /// #314: before the fix a slow polish surfaced as "Unable to connect to the configured
    /// LLM polishing endpoint", sending field debugging after a network that was fine.
    /// The failure must say it was slow, in one line, and still name the endpoint.
    func testTimedOutPolishReportsSlownessNotAConnectionFailure() async throws {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        settings.polishingBackendMode = .managedLocal

        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        // Fails the way the real service does when URLSession gives up on a slow
        // endpoint: through the service's own transport-error classification,
        // so the test covers it.
        viewModel.llmPolishingService = FakePolishingService(
            failing: LLMPolishingService.polishingError(
                forTransportError: URLError(.timedOut),
                timeoutSeconds: LLMPolishingService.requestTimeoutInterval
            )
        )
        // Same modal-alert guard as the sibling tests (AGENTS.md).
        viewModel.session.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        viewModel.session.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.transcript.currentDictationEventText = "polish this long answer"

        viewModel.session.finishStoppedSession(promotePendingSegment: false)
        await awaitStoppedSessionCommit(viewModel)

        XCTAssertEqual(viewModel.statusText, "LLM polishing failed.")
        let lastError = try XCTUnwrap(viewModel.lastError, "a timeout must not fail silently")
        XCTAssertTrue(
            lastError.contains("took longer than 40 seconds"),
            "must say the polish was slow: \(lastError)"
        )
        XCTAssertFalse(
            lastError.localizedCaseInsensitiveContains("unable to connect"),
            "a slow endpoint must not read as unreachable: \(lastError)"
        )
        XCTAssertTrue(
            lastError.contains("127.0.0.1:8472"),
            "must name the endpoint the request went to: \(lastError)"
        )
        XCTAssertFalse(lastError.contains("\n"), "the failure summary is one line: \(lastError)")
    }

    /// The details formatter itself: the given endpoint URL (sanitized) is
    /// named both with and without underlying error details.
    func testConnectionTechnicalDetailsNameTheGivenEndpoint() {
        let endpoint = URL(string: "http://127.0.0.1:8472/v1/chat/completions")!

        XCTAssertEqual(
            PolishOutcomeClassifier.connectionTechnicalDetails(
                "request timed out", endpointURL: endpoint
            ),
            "request timed out [endpoint: http://127.0.0.1:8472/v1/chat/completions]"
        )
        XCTAssertEqual(
            PolishOutcomeClassifier.connectionTechnicalDetails(
                "  ", endpointURL: endpoint
            ),
            "Unable to connect to endpoint http://127.0.0.1:8472/v1/chat/completions."
        )
    }

    /// A hosted provider answers a bad key / an unaccepted body field / an
    /// exhausted quota with an HTTP status and a JSON error body. Before the
    /// Mistral request shape landed this threw `requestFailed` into a log line
    /// and NOTHING else: no status text, no `lastError`, no alert — a silent
    /// polish failure. It must now surface as ONE line carrying the status and
    /// the provider's own reason, with the raw body left out of `lastError`
    /// (which Settings renders as the one-line failure summary).
    func testHTTPRejectionSurfacesTheStatusAndProviderReasonWithoutTheRawBody() async throws {
        let settings = makeSettings(outputMode: .overlayBuffer)
        settings.llmPolishingEnabled = true
        settings.polishingBackendMode = .managedLocal

        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = MockAppConfigStore()
        // The shape a live Mistral rejection actually has (probe, 2026-09-15):
        // an HTTP status plus an `object`/`message`/`type`/`code` envelope.
        // `message` is the diagnosis; everything around it is noise that must
        // not reach the UI.
        viewModel.llmPolishingService = FakePolishingService(
            failing: LLMPolishingError.requestFailed(
                statusCode: 401,
                body: #"{"object":"error","message":"Unauthorized","type":"invalid_request_error","param":null,"code":"1100","request_id":"abc123"}"#
            )
        )
        // Same modal-alert guard as the sibling tests (AGENTS.md).
        viewModel.session.isShowingConnectionFailureAlert = true
        retainForTestProcessLifetime(viewModel)

        viewModel.session.sessionOutputMode = .overlayBuffer
        viewModel.isFinalizingStop = true
        viewModel.transcript.currentDictationEventText = "polish this text"

        viewModel.session.finishStoppedSession(promotePendingSegment: false)
        await awaitStoppedSessionCommit(viewModel)

        XCTAssertEqual(viewModel.statusText, "LLM polishing failed.")
        let lastError = try XCTUnwrap(
            viewModel.lastError,
            "an HTTP rejection must not fail silently"
        )
        XCTAssertTrue(lastError.contains("HTTP 401"), "must name the status: \(lastError)")
        XCTAssertTrue(
            lastError.contains("Unauthorized"),
            "must carry the provider's own reason: \(lastError)"
        )
        // The envelope around that reason is noise: a JSON body in a one-line
        // summary is exactly what the popover/Settings copy rule forbids.
        XCTAssertFalse(
            lastError.contains("request_id"),
            "the provider's raw body must stay in the log, not the summary: \(lastError)"
        )
        XCTAssertFalse(
            lastError.contains("invalid_request_error"),
            "the provider's raw body must stay in the log, not the summary: \(lastError)"
        )
        XCTAssertFalse(
            lastError.contains("\n"),
            "the failure summary is one line: \(lastError)"
        )
        XCTAssertTrue(
            lastError.contains("127.0.0.1:8472"),
            "must name the endpoint the request went to: \(lastError)"
        )
    }

    /// The summary copy itself: one line, naming the status and — where the
    /// status says which — what to check. A wrong key must never read as
    /// "unable to connect", which sends field debugging after a network that
    /// was never at fault.
    func testRejectionMessagesAreOneLineNamingTheStatus() {
        let cases: [(status: Int, needle: String)] = [
            (400, "rejected the request"),
            (401, "API key"),
            (403, "API key"),
            (404, "model or path"),
            (422, "request body"),
            (429, "rate limiting"),
            (503, "failed to answer"),
            (418, "rejected the request"),
        ]
        for (status, needle) in cases {
            let message = PolishOutcomeClassifier.llmPolishingRejectionMessage(
                statusCode: status,
                body: ""
            )
            XCTAssertTrue(
                message.contains("HTTP \(status)"),
                "HTTP \(status) summary must name the status: \(message)"
            )
            XCTAssertTrue(
                message.contains(needle),
                "HTTP \(status) summary must read sensibly: \(message)"
            )
            XCTAssertFalse(
                message.lowercased().contains("unable to connect"),
                "HTTP \(status) is an answered request, not a connection failure: \(message)"
            )
            XCTAssertFalse(
                message.contains("\n"),
                "the summary is one line: \(message)"
            )
        }
    }

    /// The live 2026-09-15 Mistral probe: an unsupported body field comes back
    /// as HTTP 400 whose `message` IS the diagnosis. Without it the summary
    /// would say only "rejected the request", which names no field and sends
    /// the reader to the log for a one-line answer.
    func testRejectionMessageCarriesTheProviderReasonForABadBodyField() {
        let body = #"{"object":"error","message":"top_k sampling is not enabled for this model","type":"invalid_request_invalid_args","param":null,"code":"3051","raw_status_code":400}"#
        let message = PolishOutcomeClassifier.llmPolishingRejectionMessage(statusCode: 400, body: body)

        XCTAssertEqual(
            message,
            "The LLM polishing endpoint rejected the request (HTTP 400): "
                + "top_k sampling is not enabled for this model."
        )
    }

    /// Body-to-one-line extraction, across the error envelopes we actually
    /// meet — and the refusals: an unparseable or empty body must NOT become
    /// UI text, and a paragraph must not widen the alert.
    func testProviderErrorMessageExtractionIsBoundedAndShapeTolerant() {
        // Mistral's envelope.
        XCTAssertEqual(
            PolishOutcomeClassifier.providerErrorMessage(
                inBody: #"{"object":"error","message":"Unauthorized","code":"1100"}"#
            ),
            "Unauthorized."
        )
        // OpenAI-shaped servers nest it.
        XCTAssertEqual(
            PolishOutcomeClassifier.providerErrorMessage(
                inBody: #"{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error"}}"#
            ),
            "Incorrect API key provided."
        )
        // A nested `detail`, as the realtime surface can send.
        XCTAssertEqual(
            PolishOutcomeClassifier.providerErrorMessage(
                inBody: #"{"error":{"message":{"detail":"Model not found"}}}"#
            ),
            "Model not found."
        )
        // Newlines are flattened — the summary is one line, always.
        XCTAssertEqual(
            PolishOutcomeClassifier.providerErrorMessage(
                inBody: #"{"message":"first line\nsecond line"}"#
            ),
            "first line second line."
        )
        // A paragraph is truncated rather than pasted whole.
        let long = String(repeating: "x", count: 400)
        let truncated = PolishOutcomeClassifier.providerErrorMessage(
            inBody: #"{"message":"\#(long)"}"#
        )
        // 160 characters of provider text plus the ellipsis that says so.
        XCTAssertEqual(truncated?.count, 161)
        XCTAssertEqual(truncated?.hasSuffix("…"), true)
        // Not JSON, no message, empty message: no UI text at all.
        XCTAssertNil(PolishOutcomeClassifier.providerErrorMessage(inBody: "<html>502 Bad Gateway</html>"))
        XCTAssertNil(PolishOutcomeClassifier.providerErrorMessage(inBody: ""))
        XCTAssertNil(PolishOutcomeClassifier.providerErrorMessage(inBody: #"{"object":"error"}"#))
        XCTAssertNil(PolishOutcomeClassifier.providerErrorMessage(inBody: #"{"message":"   "}"#))
    }

    // MARK: - Harness (mirrors the token-guard suite)

}
