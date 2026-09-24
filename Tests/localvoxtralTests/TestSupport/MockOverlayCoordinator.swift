import CoreGraphics
import Foundation
@testable import localvoxtral

/// Records every call and shows nothing. `commitOutcome` is what
/// `commitIfNeeded` reports.
@MainActor
final class MockOverlayCoordinator: OverlayBufferSessionCoordinating {
    struct BufferCall {
        let displayText: String
        let commitText: String
    }

    var commitOutcome: OverlayBufferCommitOutcome = .succeeded
    var commitTargetAppPID: pid_t? = nil

    var startSessionAnchors: [OverlayAnchor?] = []
    var beginFinalizingCalls: [BufferCall] = []
    var refreshCalls: [BufferCall] = []
    var commitCallCount = 0
    /// The commit text the overlay held at each `commitIfNeeded`: the buffer
    /// last handed to `beginFinalizing` or `refresh`.
    var committedTexts: [String] = []
    /// Runs inside `commitIfNeeded`, for tests that order the commit against
    /// what follows it.
    var onCommit: (() -> Void)?
    private var commitBufferText = ""
    var dismissHoldVisibilities: [TimeInterval] = []
    var dismissAfterHoldCallCount: Int { dismissHoldVisibilities.count }
    var lastDismissAfterHoldMinimumVisibility: TimeInterval? { dismissHoldVisibilities.last }
    var resetCallCount = 0
    var captureLiveCommitTargetAppPIDCallCount = 0
    var markPolishedCalls: [Bool] = []

    func resolveAnchorNow() -> OverlayAnchor {
        OverlayAnchor(
            targetRect: CGRect(x: 0, y: 0, width: 100, height: 24),
            source: .windowCenter
        )
    }

    func startSession(preResolvedAnchor: OverlayAnchor?, claudeJoin _: OverlayClaudeJoinBadge) {
        startSessionAnchors.append(preResolvedAnchor)
    }

    func beginFinalizing(displayBufferText: String, commitBufferText: String) {
        beginFinalizingCalls.append(
            BufferCall(displayText: displayBufferText, commitText: commitBufferText)
        )
        self.commitBufferText = commitBufferText
    }

    func refresh(displayBufferText: String, commitBufferText: String) {
        refreshCalls.append(
            BufferCall(displayText: displayBufferText, commitText: commitBufferText)
        )
        self.commitBufferText = commitBufferText
    }

    @discardableResult
    func commitIfNeeded(
        using _: OverlayTextCommitting,
        autoCopyEnabled _: Bool
    ) -> OverlayBufferCommitOutcome {
        commitCallCount += 1
        committedTexts.append(commitBufferText)
        onCommit?()
        return commitOutcome
    }

    func dismissAfterHold(minimumVisibility: TimeInterval) {
        dismissHoldVisibilities.append(minimumVisibility)
    }

    func reset() {
        resetCallCount += 1
    }

    func captureLiveCommitTargetAppPID() {
        captureLiveCommitTargetAppPIDCallCount += 1
    }

    func markPolished(_ polished: Bool) {
        markPolishedCalls.append(polished)
    }
}
