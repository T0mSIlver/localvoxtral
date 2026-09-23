import Foundation
import XCTest
@testable import localvoxtral

// Tests for the issue #13 raw-delta instrumentation: when the hidden
// `debug.log_realtime_deltas` toggle is on, `DictationViewModel` must log the
// exact, pre-processing payload of every received realtime event (partial
// deltas quoted so whitespace/punctuation is visible, final transcripts, and
// session boundaries) with a per-session sequence number — BEFORE any
// merge/preprocess/insertion processing. When off, the logging call path must
// not be entered at all.
//
// OSLog output can't be captured in-process, so we observe through
// `Dependencies.onRealtimeDeltaLogRecord`, which is called from the same
// gated path as `Log.deltas`. The records mirror what is logged. The log's
// own sequencing rules are pinned by `RealtimeDeltaLogTests`; these prove the
// view model routes every event through it, behind the setting.
#if DEBUG
@MainActor
final class DictationViewModelDeltaLoggingTests: XCTestCase {
    private var captured: [DebugRealtimeDeltaLogRecord] = []

    /// Build a ViewModel whose delta-log sink captures every emission in
    /// arrival order. `enableDeltaLogging` controls the toggle so each test
    /// pins the exact state under test.
    private func makeViewModel(enableDeltaLogging: Bool) -> DictationViewModel {
        let suiteName = "localvoxtral.DictationViewModelDeltaLoggingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        settings.debugLogRealtimeDeltas = enableDeltaLogging

        captured = []
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false,
            dependencies: DictationViewModel.Dependencies(
                onRealtimeDeltaLogRecord: { [weak self] record in
                    self?.captured.append(record)
                }
            )
        )
        retainForTestProcessLifetime(viewModel)

        return viewModel
    }

    // MARK: - Toggle off: logging path not entered

    func testDeltaLogging_disabled_neverEmitsAndDoesNotAdvanceSequence() {
        // With the toggle off, sending a full mix of events must not enter the
        // logging path at all: the sink receives nothing AND the per-session
        // sequence counter (only ever mutated inside the gated path) stays 0.
        // The two assertions together prove "no logging call path is hit".
        let viewModel = makeViewModel(enableDeltaLogging: false)

        viewModel.session.handle(event: .connected)
        viewModel.session.handle(event: .partialTranscript("spar"))
        viewModel.session.handle(event: .partialTranscript("isce"))
        viewModel.session.handle(event: .partialTranscript("."))
        viewModel.session.handle(event: .finalTranscript("sparisce."))
        viewModel.session.handle(event: .transcriptionFinalized)
        viewModel.session.handle(event: .disconnected)

        XCTAssertTrue(captured.isEmpty, "sink must not fire when toggle is off")
        XCTAssertEqual(
            viewModel.session.realtimeDeltaLog.sequence, 0,
            "sequence counter must not advance when toggle is off")
    }

    // MARK: - Toggle on: exact payloads + arrival order + sequence

    func testDeltaLogging_enabled_capturesPartialDeltasInArrivalOrderWithExactPayloads() {
        // The core of issue #13: capture the EXACT delta string the backend
        // delivered, in arrival order, before any processing. The mid-word
        // punctuation case ("sparis", ".", "ce") is precisely what we need to
        // see upstream; the app must record it verbatim.
        let viewModel = makeViewModel(enableDeltaLogging: true)

        viewModel.session.handle(event: .partialTranscript("sparis"))
        viewModel.session.handle(event: .partialTranscript("."))
        viewModel.session.handle(event: .partialTranscript("ce"))

        XCTAssertEqual(captured.count, 3)
        XCTAssertEqual(captured[0].kind, .partialDelta)
        XCTAssertEqual(captured[0].sequence, 0)
        XCTAssertEqual(captured[0].payload, "sparis")
        XCTAssertEqual(captured[1].kind, .partialDelta)
        XCTAssertEqual(captured[1].sequence, 1)
        XCTAssertEqual(captured[1].payload, ".")
        XCTAssertEqual(captured[2].kind, .partialDelta)
        XCTAssertEqual(captured[2].sequence, 2)
        XCTAssertEqual(captured[2].payload, "ce")
    }

    func testDeltaLogging_enabled_capturesWhitespaceExactly() {
        // Punctuation placement isn't the only thing to verify — leading,
        // inner, and trailing whitespace must survive to the log so a reviewer
        // can see it in the capture. The sink holds the raw string; the Logger
        // quotes it via `.debugDescription` (verified in source).
        let viewModel = makeViewModel(enableDeltaLogging: true)

        let exact = "  lead\u{00a0}space\ntrail\t"
        viewModel.session.handle(event: .partialTranscript(exact))

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].payload, exact)
    }

    func testDeltaLogging_enabled_capturesFinalTranscriptFinalizedAndBoundaries() {
        // A realistic single-session flow: connect, partial, final, finalized.
        // Each event is captured with a monotonic per-session sequence.
        let viewModel = makeViewModel(enableDeltaLogging: true)

        viewModel.session.handle(event: .connected)
        viewModel.session.handle(event: .partialTranscript("hi"))
        viewModel.session.handle(event: .finalTranscript("hi."))
        viewModel.session.handle(event: .transcriptionFinalized)
        viewModel.session.handle(event: .disconnected)

        XCTAssertEqual(
            captured.map(\.kind),
            [.sessionConnected, .partialDelta, .finalTranscript, .transcriptionFinalized,
                .sessionDisconnected])
        XCTAssertEqual(captured.map(\.sequence), [0, 1, 2, 3, 4])
        XCTAssertEqual(captured[0].payload, nil, "connected has no string payload")
        XCTAssertEqual(captured[1].payload, "hi")
        XCTAssertEqual(captured[2].payload, "hi.")
        XCTAssertEqual(captured[3].payload, nil, "finalized has no string payload")
        XCTAssertEqual(captured[4].payload, nil, "disconnected has no string payload")
    }

    func testDeltaLogging_enabled_sequenceResetsWhenNewSessionConnects() {
        // The sequence is per-session: a fresh `.connected` boundary must reset
        // it to 0 so a reviewer can correlate delta order within one session.
        let viewModel = makeViewModel(enableDeltaLogging: true)

        // Session 1.
        viewModel.session.handle(event: .connected)            // seq 0 (reset)
        viewModel.session.handle(event: .partialTranscript("a"))  // seq 1
        viewModel.session.handle(event: .partialTranscript("b"))  // seq 2
        // Session 2 begins — sequence must reset.
        viewModel.session.handle(event: .connected)            // seq 0 (reset)
        viewModel.session.handle(event: .partialTranscript("c"))  // seq 1

        let connectedRecords = captured.filter { $0.kind == .sessionConnected }
        XCTAssertEqual(connectedRecords.map(\.sequence), [0, 0])

        let partialRecords = captured.filter { $0.kind == .partialDelta }
        XCTAssertEqual(partialRecords.map(\.sequence), [1, 2, 1])
        XCTAssertEqual(partialRecords.map(\.payload), ["a", "b", "c"])
    }

    func testDeltaLogging_enabled_capturesStatusAndErrorPayloads() {
        // Status/error events also carry payloads worth capturing during a
        // debugging session.
        let viewModel = makeViewModel(enableDeltaLogging: true)

        viewModel.session.handle(event: .status("Session ready."))
        viewModel.session.handle(event: .error("rate limited"))

        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[0].kind, .status)
        XCTAssertEqual(captured[0].payload, "Session ready.")
        XCTAssertEqual(captured[1].kind, .error)
        XCTAssertEqual(captured[1].payload, "rate limited")
    }

    // MARK: - Transcription stopped (#314)

    /// Before #314 a helper that stopped transcribing mid-dictation arrived as a generic
    /// error: the popover read "Realtime error." and "See Console for details.", hiding the
    /// one actionable sentence. That sentence is now the status line itself, and nothing
    /// sets `lastError`, so the popover shows no Console hint under it.
    func testTranscriptionStoppedMidDictationBecomesTheStatusLine() {
        let viewModel = makeViewModel(enableDeltaLogging: true)
        viewModel.isDictating = true
        viewModel.statusText = "Transcribing..."
        let message = "10-minute limit reached; start again."

        viewModel.session.handle(event: .transcriptionStopped(message))

        XCTAssertEqual(viewModel.statusText, message)
        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(captured.map(\.kind), [.error])
        XCTAssertEqual(captured.map(\.payload), [message])
    }

    func testTranscriptionStoppedOutsideADictationLeavesTheStatusAlone() {
        let viewModel = makeViewModel(enableDeltaLogging: false)
        viewModel.statusText = "Ready"

        viewModel.session.handle(event: .transcriptionStopped("Dictation stopped early; start again."))

        XCTAssertEqual(viewModel.statusText, "Ready")
        XCTAssertNil(viewModel.lastError)
    }
}

#endif
