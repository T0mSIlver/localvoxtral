import Foundation
import Observation
@testable import localvoxtral

/// An onboarding driver that does no work: `start` records the request and
/// seeds `.pending`, `cancel` counts.
@MainActor
@Observable
final class FakeOnboardingBootstrapDriver: OnboardingBootstrapDriving {
    private(set) var itemStates: [OnboardingItemID: OnboardingItemState] = [:]

    @ObservationIgnored private(set) var startCallCount = 0
    @ObservationIgnored private(set) var cancelCallCount = 0
    @ObservationIgnored private(set) var lastStart: (dictation: Bool, polishing: Bool)?

    func start(dictation: Bool, polishing: Bool) {
        startCallCount += 1
        lastStart = (dictation, polishing)

        var seeded: [OnboardingItemID: OnboardingItemState] = [:]
        if dictation { seeded[.dictation] = .pending }
        if polishing { seeded[.polishing] = .pending }
        itemStates = seeded
    }

    func cancel() {
        cancelCallCount += 1
    }
}
