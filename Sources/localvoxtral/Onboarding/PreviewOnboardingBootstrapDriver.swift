import Foundation
import Observation

/// Scripted onboarding driver for tests and SwiftUI previews. It performs no
/// real work: `start` records the request and seeds `.pending`, then callers
/// (tests) drive transitions deterministically via `setState`/`advance`. No
/// wall-clock, no backend — every state change is caller-triggered.
@MainActor
@Observable
final class PreviewOnboardingBootstrapDriver: OnboardingBootstrapDriving {
    /// A scripted frame: the item states to apply on the next `advance()`.
    typealias Frame = [OnboardingItemID: OnboardingItemState]

    private(set) var itemStates: [OnboardingItemID: OnboardingItemState] = [:]

    @ObservationIgnored private(set) var startCallCount = 0
    @ObservationIgnored private(set) var cancelCallCount = 0
    @ObservationIgnored private(set) var lastStart: (dictation: Bool, polishing: Bool)?

    @ObservationIgnored private var frames: [Frame]
    @ObservationIgnored private var nextFrameIndex = 0

    /// - Parameter frames: optional scripted frames applied one-per-`advance()`.
    init(frames: [Frame] = []) {
        self.frames = frames
    }

    func start(dictation: Bool, polishing: Bool) {
        startCallCount += 1
        lastStart = (dictation, polishing)
        nextFrameIndex = 0

        var seeded: [OnboardingItemID: OnboardingItemState] = [:]
        if dictation { seeded[.dictation] = .pending }
        if polishing { seeded[.polishing] = .pending }
        itemStates = seeded
    }

    func cancel() {
        cancelCallCount += 1
    }

    // MARK: - Test / preview controls

    /// Apply the next scripted frame, if any remain. Returns true when a frame
    /// was applied.
    @discardableResult
    func advance() -> Bool {
        guard nextFrameIndex < frames.count else { return false }
        itemStates = frames[nextFrameIndex]
        nextFrameIndex += 1
        return true
    }

    /// Directly set one item's state.
    func setState(_ state: OnboardingItemState, for id: OnboardingItemID) {
        itemStates[id] = state
    }

    /// Replace the full item-state map.
    func setStates(_ states: [OnboardingItemID: OnboardingItemState]) {
        itemStates = states
    }
}
