import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class TerminalTargetDetectorTests: XCTestCase {
    // DictationViewModel owns app-lifetime services. Retain test instances for
    // the process duration so teardown does not race service shutdown.
    private static var retainedViewModels: [DictationViewModel] = []

    override func tearDown() async throws {
        TerminalTargetDetector.debugFrontmostBundleIDOverride = nil
        TerminalTargetDetector.debugFocusedElementProbeOverride = nil
        TerminalTargetDetector.debugSecureEventInputOverride = nil
        try await super.tearDown()
    }

    // MARK: - Bundle allowlist (pure)

    func testAllowlistMatchesKnownTerminalBundleIDs() {
        let knownTerminals = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable",
            "com.github.wez.wezterm",
            "net.kovidgoyal.kitty",
            "org.alacritty",
            "co.zeit.hyper",
            "org.tabby",
            "com.raphaelamorim.rio",
        ]
        for bundleID in knownTerminals {
            XCTAssertTrue(
                TerminalTargetDetector.isTerminalLikeBundleID(bundleID),
                "\(bundleID) should be terminal-like"
            )
        }
    }

    func testAllowlistMatchesWarpChannelVariants() {
        for bundleID in ["dev.warp.Warp-Preview", "dev.warp.Warp-Dev", "dev.warp.Warp-Beta"] {
            XCTAssertTrue(
                TerminalTargetDetector.isTerminalLikeBundleID(bundleID),
                "\(bundleID) should match the Warp prefix"
            )
        }
    }

    func testAllowlistRejectsUnknownNilAndEditorBundleIDs() {
        XCTAssertFalse(TerminalTargetDetector.isTerminalLikeBundleID(nil))
        XCTAssertFalse(TerminalTargetDetector.isTerminalLikeBundleID(""))
        // VS Code/Cursor editors are AX-writable — never allowlisted.
        XCTAssertFalse(TerminalTargetDetector.isTerminalLikeBundleID("com.microsoft.VSCode"))
        XCTAssertFalse(TerminalTargetDetector.isTerminalLikeBundleID("com.todesktop.230313mzl4w4u92"))
        XCTAssertFalse(TerminalTargetDetector.isTerminalLikeBundleID("com.apple.Safari"))
        // Prefix matching must not fire on unrelated dev.warp-ish strings.
        XCTAssertFalse(TerminalTargetDetector.isTerminalLikeBundleID("dev.warp"))
        XCTAssertFalse(TerminalTargetDetector.isTerminalLikeBundleID("dev.warplike.Other"))
    }

    // MARK: - Decision logic (injected AX probe)

    func testUnknownBundleWithUnsettableValueIsTerminalLike() {
        let decision = TerminalTargetDetector.decision(forBundleID: "com.example.unknown") {
            .valueNotSettable
        }
        XCTAssertTrue(decision.isTerminalLike)
        XCTAssertEqual(decision.reason, .axProbeValueNotSettable)
    }

    func testUnknownBundleWithMissingFocusedElementIsTerminalLike() {
        let decision = TerminalTargetDetector.decision(forBundleID: "com.example.unknown") {
            .noFocusedElement
        }
        XCTAssertTrue(decision.isTerminalLike)
        XCTAssertEqual(decision.reason, .axProbeNoFocusedElement)
    }

    func testUnknownBundleWithSettableValueIsNotTerminalLike() {
        let decision = TerminalTargetDetector.decision(forBundleID: "com.example.unknown") {
            .valueSettable
        }
        XCTAssertFalse(decision.isTerminalLike)
        XCTAssertEqual(decision.reason, .axProbeValueSettable)
    }

    func testUnknownBundleWithUnavailableProbeIsNotTerminalLike() {
        // AX trust missing / transient AX errors must not flip ordinary apps
        // terminal-like — "couldn't tell" is distinct from "confirmed grid".
        let decision = TerminalTargetDetector.decision(forBundleID: "com.example.unknown") {
            .probeUnavailable
        }
        XCTAssertFalse(decision.isTerminalLike)
        XCTAssertEqual(decision.reason, .axProbeUnavailable)
    }

    func testAllowlistedBundleIsTerminalLikeWithoutProbing() {
        let decision = TerminalTargetDetector.decision(forBundleID: "com.mitchellh.ghostty") {
            XCTFail("AX probe must not run for allowlisted bundles")
            return .valueSettable
        }
        XCTAssertTrue(decision.isTerminalLike)
        XCTAssertEqual(decision.reason, .bundleMatch)
    }

    func testDetectCurrentTargetUsesInjectedSeams() {
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.example.unknown" }
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueNotSettable }
        let decision = TerminalTargetDetector.detectCurrentTarget()
        XCTAssertTrue(decision.isTerminalLike)
        XCTAssertEqual(decision.reason, .axProbeValueNotSettable)

        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueSettable }
        XCTAssertFalse(TerminalTargetDetector.detectCurrentTarget().isTerminalLike)
    }

    // MARK: - Capture-at-begin / consume-at-audio-start lifecycle

    func testBeginDictationSessionCapturesVerdictBeforeConnect() {
        // Pins the wiring: the verdict must be sampled inside
        // beginDictationSession (before the socket opens), like
        // preResolvedOverlayAnchor. Overlay mode avoids the live-auto-paste
        // accessibility fail-fast path (no TCC prompt on the runner).
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.apple.Terminal" }
        TerminalTargetDetector.debugSecureEventInputOverride = { true }

        let viewModel = makeViewModel(outputMode: .overlayBuffer)
        viewModel.settings.realtimeAPIEndpointURL = "ws://127.0.0.1:1/realtime"
        viewModel.isShowingConnectionFailureAlert = true
        Self.retainedViewModels.append(viewModel)

        viewModel.beginDictationSession(outputMode: .overlayBuffer)

        XCTAssertEqual(
            viewModel.preCapturedSessionTargetVerdict,
            DictationViewModel.SessionTargetVerdict(
                decision: .init(isTerminalLike: true, reason: .bundleMatch),
                secureKeyboardEntryEnabled: true
            )
        )

        viewModel.abortConnectingSession()
    }

    func testApplyConsumesPreCapturedVerdictInsteadOfReprobing() {
        // Capture with the terminal frontmost and secure input on...
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.mitchellh.ghostty" }
        TerminalTargetDetector.debugSecureEventInputOverride = { true }

        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        viewModel.captureSessionTargetVerdict()

        // ...then simulate a focus switch during connect: live state now says
        // an ordinary writable app with secure input off. The session must
        // keep the captured values, not reprobe.
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.example.editor" }
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueSettable }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }

        viewModel.applyPreCapturedSessionTargetVerdict()

        XCTAssertTrue(viewModel.sessionTargetIsTerminalLike)
        XCTAssertEqual(
            viewModel.lastError,
            DictationViewModel.secureKeyboardEntryWarningMessage
        )
        XCTAssertNil(viewModel.preCapturedSessionTargetVerdict, "capture is consumed once")
    }

    // MARK: - Secure Keyboard Entry warning lifecycle

    func testSecureWarningDoesNotClobberAccessibilityWarning() {
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.apple.Terminal" }
        TerminalTargetDetector.debugSecureEventInputOverride = { true }

        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        viewModel.lastError = DictationViewModel.liveAutoPasteAccessibilityWarningMessage

        viewModel.captureSessionTargetVerdict()
        viewModel.applyPreCapturedSessionTargetVerdict()

        XCTAssertEqual(
            viewModel.lastError,
            DictationViewModel.liveAutoPasteAccessibilityWarningMessage,
            "the Accessibility-trust warning outranks the secure-input warning"
        )
        XCTAssertTrue(viewModel.sessionTargetIsTerminalLike, "verdict still applies")
    }

    func testStaleSecureWarningClearedAtNextSessionStartWhenSecureInputOff() {
        // Regression: the warning used to wedge in lastError forever.
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.apple.Terminal" }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }

        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        viewModel.lastError = DictationViewModel.secureKeyboardEntryWarningMessage

        viewModel.captureSessionTargetVerdict()
        viewModel.applyPreCapturedSessionTargetVerdict()

        XCTAssertNil(viewModel.lastError, "stale warning cleared once secure input is off")
        XCTAssertTrue(viewModel.sessionTargetIsTerminalLike)
    }

    func testSecureWarningClearedAtSessionEnd() {
        // Regression: session end must release the warning (mirrors the
        // websocketReceiveFailed clearing), not leave it in the popover.
        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        Self.retainedViewModels.append(viewModel)
        viewModel.lastError = DictationViewModel.secureKeyboardEntryWarningMessage
        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isDictating = true

        viewModel.stopDictation(reason: "test", finalizeRemainingAudio: false)

        XCTAssertNil(viewModel.lastError)
        XCTAssertEqual(viewModel.statusText, "Ready")
    }

    func testSessionEndKeepsUnrelatedErrors() {
        // The session-end clear is token-scoped: other errors must survive.
        let viewModel = makeViewModel(outputMode: .liveAutoPaste)
        Self.retainedViewModels.append(viewModel)
        viewModel.lastError = "mlx-lm failed to start."
        viewModel.sessionOutputMode = .liveAutoPaste
        viewModel.isDictating = true

        viewModel.stopDictation(reason: "test", finalizeRemainingAudio: false)

        XCTAssertEqual(viewModel.lastError, "mlx-lm failed to start.")
    }

    // MARK: - Fixture

    private func makeViewModel(outputMode: DictationOutputMode) -> DictationViewModel {
        let suiteName = "localvoxtral.TerminalTargetDetectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(defaults: defaults, environment: [:])
        settings.dictationOutputMode = outputMode
        return DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: TargetDetectorNoopOverlayCoordinator(),
            startRuntimeServices: false
        )
    }
}

@MainActor
private final class TargetDetectorNoopOverlayCoordinator: OverlayBufferSessionCoordinating {
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
