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
    /// When set, `commitIfNeeded` hands the buffer to the committer it is
    /// given, as the real overlay does, for tests of where the text went.
    var insertsThroughCommitter = false
    /// Off, the committer gets no target pid, so a test can name a target
    /// without the insertion trying to activate that (absent) app.
    var passesTargetPIDToCommitter = true
    /// Runs after each `refresh` is recorded, for tests that wait for the
    /// buffer to show a text.
    var onRefresh: ((BufferCall) -> Void)?
    private var commitBufferText = ""
    var dismissHoldVisibilities: [TimeInterval] = []
    var dismissAfterHoldCallCount: Int { dismissHoldVisibilities.count }
    var lastDismissAfterHoldMinimumVisibility: TimeInterval? { dismissHoldVisibilities.last }
    var resetCallCount = 0
    var markPolishedCalls: [Bool] = []
    var markPolishingCalls: [Bool] = []
    var micLevels: [Double] = []
    /// The polish-to-close calls in order (#1074), for tests of what the
    /// user sees against when the text goes in.
    enum Event: Equatable {
        case polishing(Bool)
        case polished(Bool)
        case committed(String)
        case held(TimeInterval)
    }
    var events: [Event] = []
    /// One entry per commit after a `markPolished`: whether the commit ran
    /// in the same main-actor turn, with no suspension since. A task queued
    /// at `markPolished` flips the flag the moment the code yields.
    var commitsInPolishedTurn: [Bool] = []
    private var polishedTurnEnded: Bool?
    /// Every destination strip the overlay was asked to show (#840).
    var shownDestinations: [OverlayDestinationStrip?] = []
    /// Every draft a review asked the overlay to show (#927).
    var shownDraftReviews: [QuickCaptureDraftSnapshot?] = []

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
        let call = BufferCall(displayText: displayBufferText, commitText: commitBufferText)
        refreshCalls.append(call)
        self.commitBufferText = commitBufferText
        onRefresh?(call)
    }

    @discardableResult
    func commitIfNeeded(
        using textCommitter: OverlayTextCommitting,
        autoCopyEnabled _: Bool
    ) -> OverlayBufferCommitOutcome {
        commitCallCount += 1
        committedTexts.append(commitBufferText)
        events.append(.committed(commitBufferText))
        if let polishedTurnEnded {
            commitsInPolishedTurn.append(!polishedTurnEnded)
        }
        if insertsThroughCommitter,
           !textCommitter.insertTextPrioritizingKeyboard(
               commitBufferText, preferredAppPID: passesTargetPIDToCommitter ? commitTargetAppPID : nil
           ).isSuccess {
            return .failed(message: "insert failed")
        }
        onCommit?()
        return commitOutcome
    }

    func dismissAfterHold(minimumVisibility: TimeInterval) {
        dismissHoldVisibilities.append(minimumVisibility)
        events.append(.held(minimumVisibility))
    }

    func reset() {
        resetCallCount += 1
    }

    func captureLiveCommitTargetAppPID() {}

    func showDestinations(_ strip: OverlayDestinationStrip?) {
        shownDestinations.append(strip)
    }

    func showDraftReview(_ draft: QuickCaptureDraftSnapshot?) {
        shownDraftReviews.append(draft)
    }

    func markPolished(_ polished: Bool) {
        markPolishedCalls.append(polished)
        events.append(.polished(polished))
        polishedTurnEnded = false
        Task { @MainActor [weak self] in self?.polishedTurnEnded = true }
    }

    func markPolishing(_ polishing: Bool) {
        markPolishingCalls.append(polishing)
        events.append(.polishing(polishing))
    }

    var showsPolishChange: Bool { markPolishedCalls.last ?? false }

    func updateMicLevel(_ level: Double) {
        micLevels.append(level)
    }
}
