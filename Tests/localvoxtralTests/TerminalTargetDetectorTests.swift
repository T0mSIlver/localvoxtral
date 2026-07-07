import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class TerminalTargetDetectorTests: XCTestCase {
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

    // MARK: - Session-start wiring + Secure Keyboard Entry warning

    func testSessionStartStoresTerminalVerdictAndWarnsOnSecureKeyboardEntry() {
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.apple.Terminal" }
        TerminalTargetDetector.debugFocusedElementProbeOverride = {
            XCTFail("AX probe must not run for allowlisted bundles")
            return .valueSettable
        }
        TerminalTargetDetector.debugSecureEventInputOverride = { true }

        let viewModel = makeViewModel()
        XCTAssertFalse(viewModel.sessionTargetIsTerminalLike)

        viewModel.refreshSessionTargetVerdictAtSessionStart()

        XCTAssertTrue(viewModel.sessionTargetIsTerminalLike)
        XCTAssertEqual(
            viewModel.lastError,
            DictationViewModel.secureKeyboardEntryWarningMessage
        )
    }

    func testSessionStartWithoutSecureInputLeavesNoWarningAndRefreshesVerdict() {
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.apple.Terminal" }
        TerminalTargetDetector.debugSecureEventInputOverride = { false }

        let viewModel = makeViewModel()
        viewModel.refreshSessionTargetVerdictAtSessionStart()
        XCTAssertTrue(viewModel.sessionTargetIsTerminalLike)
        XCTAssertNil(viewModel.lastError)

        // A later session against an ordinary writable text field resets the verdict.
        TerminalTargetDetector.debugFrontmostBundleIDOverride = { "com.example.editor" }
        TerminalTargetDetector.debugFocusedElementProbeOverride = { .valueSettable }
        viewModel.refreshSessionTargetVerdictAtSessionStart()
        XCTAssertFalse(viewModel.sessionTargetIsTerminalLike)
        XCTAssertNil(viewModel.lastError)
    }

    // MARK: - Fixture

    private func makeViewModel() -> DictationViewModel {
        let suiteName = "localvoxtral.TerminalTargetDetectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(defaults: defaults, environment: [:])
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
