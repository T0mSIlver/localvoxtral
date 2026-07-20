import Foundation
import Observation

/// Production onboarding driver: kicks off `BackendManager.ensureReady` and
/// mirrors the observable `speechdStatus` / `polishdStatus` into `itemStates`.
///
/// It only ever CALLS existing backend API from main — it never mutates the
/// backend beyond the single `ensureReady` request, and the status → item-state
/// translation lives entirely in `OnboardingItemState.init(managedStatus:)`.
@MainActor
@Observable
final class LiveOnboardingBootstrapDriver: OnboardingBootstrapDriving {
    private(set) var itemStates: [OnboardingItemID: OnboardingItemState] = [:]

    @ObservationIgnored private let backendManager: any ManagedBackendManaging
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var dictationRequested = false
    @ObservationIgnored private var polishingRequested = false
    @ObservationIgnored private var isObserving = false
    #if DEBUG
    @ObservationIgnored var onItemStatesChanged: (([OnboardingItemID: OnboardingItemState]) -> Void)?
    #endif

    init(backendManager: any ManagedBackendManaging) {
        self.backendManager = backendManager
    }

    func start(dictation: Bool, polishing: Bool) {
        guard dictation || polishing else { return }
        dictationRequested = dictation
        polishingRequested = polishing

        recomputeItemStates()
        beginObservingIfNeeded()

        runTask?.cancel()
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Any failure is already reflected into `itemStates` through the
            // status observation below (ensureReady sets `.failed` on the
            // backend status before throwing), so the throw is swallowed here.
            try? await self.backendManager.ensureReady(
                dictation: dictation, polishing: polishing)
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
    }

    // MARK: - Status mirroring

    private func beginObservingIfNeeded() {
        guard !isObserving else { return }
        isObserving = true
        observeStatuses()
    }

    /// Re-arming observation: `withObservationTracking`'s `onChange` fires once,
    /// just before a tracked value mutates, so recompute-then-re-observe on the
    /// next main-actor hop keeps `itemStates` current for the whole run.
    private func observeStatuses() {
        withObservationTracking {
            _ = backendManager.speechdStatus
            _ = backendManager.polishdStatus
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.recomputeItemStates()
                self.observeStatuses()
            }
        }
    }

    private func recomputeItemStates() {
        var states: [OnboardingItemID: OnboardingItemState] = [:]
        if dictationRequested {
            states[.dictation] = OnboardingItemState(managedStatus: backendManager.speechdStatus)
        }
        if polishingRequested {
            states[.polishing] = OnboardingItemState(managedStatus: backendManager.polishdStatus)
        }
        if itemStates != states {
            itemStates = states
            #if DEBUG
            onItemStatesChanged?(states)
            #endif
        }
    }
}
