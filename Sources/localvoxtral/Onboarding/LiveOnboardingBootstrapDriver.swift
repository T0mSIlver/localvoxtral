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
    @ObservationIgnored private let waitForPendingShutdowns: @MainActor () async -> Void
    /// Items that had failed when the last start ran, shown pending until
    /// their backend leaves `.failed`.
    @ObservationIgnored private var restartedAfterFailure: Set<OnboardingItemID> = []
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var dictationRequested = false
    @ObservationIgnored private var polishingRequested = false
    @ObservationIgnored private var isObserving = false
    #if DEBUG
    var debugRunTask: Task<Void, Never>? { runTask }
    @ObservationIgnored var onItemStatesChanged: (([OnboardingItemID: OnboardingItemState]) -> Void)?
    #endif

    /// `waitForPendingShutdowns` returns once a stop the Engines model
    /// queued (picking Mistral, say) has finished.
    init(
        backendManager: any ManagedBackendManaging,
        waitForPendingShutdowns: @escaping @MainActor () async -> Void = {}
    ) {
        self.backendManager = backendManager
        self.waitForPendingShutdowns = waitForPendingShutdowns
    }

    func start(dictation: Bool, polishing: Bool) {
        guard dictation || polishing else { return }
        dictationRequested = dictation
        polishingRequested = polishing
        // A start after a failure is a retry: the row reads pending until the
        // backend leaves `.failed`, so Try again does not stay up while the
        // start waits for a shutdown (#1929).
        restartedAfterFailure = Set(itemStates.compactMap { id, state in
            if case .failed = state { return id }
            return nil
        })

        recomputeItemStates()
        beginObservingIfNeeded()

        runTask?.cancel()
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // A helper still shutting down answers as ready until the stop
            // removes it, leaving the page with nothing running (#1763).
            await self.waitForPendingShutdowns()
            guard !Task.isCancelled else { return }
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

    private func itemState(_ id: OnboardingItemID, managedStatus: ManagedBackendStatus) -> OnboardingItemState {
        let state = OnboardingItemState(managedStatus: managedStatus)
        guard case .failed = state else {
            restartedAfterFailure.remove(id)
            return state
        }
        return restartedAfterFailure.contains(id) ? .pending : state
    }

    private func recomputeItemStates() {
        var states: [OnboardingItemID: OnboardingItemState] = [:]
        if dictationRequested {
            states[.dictation] = itemState(.dictation, managedStatus: backendManager.speechdStatus)
        }
        if polishingRequested {
            states[.polishing] = itemState(.polishing, managedStatus: backendManager.polishdStatus)
        }
        if itemStates != states {
            itemStates = states
            #if DEBUG
            onItemStatesChanged?(states)
            #endif
        }
    }
}
