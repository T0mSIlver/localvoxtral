import AppKit
import Foundation
import Observation

/// The Engines pane's state and actions: backend modes, the Mistral key check
/// and model catalog, endpoint preflights, the managed engines' settings,
/// their warmup and shutdown, the download controls and the diagnostics
/// export. Owned by `DictationViewModel` and reached as `viewModel.engines`;
/// no dictation runs through it.
///
/// The one thing it asks of the session is `interruptConnectingSession`: a
/// backend the user stops from the pane (a mode switch, Pause, Cancel) is the
/// backend a connecting session may be waiting on, and that session has to
/// unwind or its connecting flag stays latched and blocks every later start.
@MainActor
@Observable
final class EnginesModel {
    @ObservationIgnored
    let settings: SettingsStore
    @ObservationIgnored
    let backendManager: any ManagedBackendManaging
    @ObservationIgnored
    private let localNetworkPermissionPreflight: any LocalNetworkPermissionPreflighting
    /// Installed by the owner once it exists (a closure over the view model
    /// cannot be formed inside its own init). Cancels the managed startup task
    /// and aborts the session waiting on it, if one is. Until then a call
    /// logs instead of silently leaving that session latched.
    @ObservationIgnored
    var interruptConnectingSession: () -> Void = {
        Log.backends.error(
            "engines: a backend stop reached no session owner; nothing was unwound"
        )
    }

    /// Result of the Engines pane's "Check key" row. Observable so the row's
    /// one-line label follows it; reset to `.idle` is the caller's business.
    var mistralAPIKeyCheckState: MistralAPIKeyCheckState = .idle
    /// The local record of Mistral requests Settings → Engines sums. Nil
    /// without runtime services (tests), so a unit test never writes the
    /// user's ledger.
    @ObservationIgnored
    private(set) var mistralUsageLedger: MistralUsageLedger?
    /// Bumped on every ledger write so the Usage row re-reads the ledger.
    private(set) var mistralUsageRevision = 0

    /// The in-flight key check. Kept awaitable so the unit suite observes the
    /// result without polling a clock.
    @ObservationIgnored
    private(set) var mistralAPIKeyCheckTask: Task<Void, Never>?

    /// The Mistral model pickers' fetch state.
    var mistralModelListState: MistralModelListState = .idle

    /// The in-flight model list fetch, awaitable for the same reason as
    /// `mistralAPIKeyCheckTask`.
    @ObservationIgnored
    private(set) var mistralModelListTask: Task<Void, Never>?

    /// The key the model list was last loaded with, so reopening the pane
    /// does not refetch a list it already has.
    @ObservationIgnored
    private var mistralModelListLoadedKey: String?

    /// Asks Mistral whether a key works. A stored property so tests never
    /// reach api.mistral.ai.
    @ObservationIgnored
    var mistralAPIKeyVerifier: any MistralAPIKeyVerifying = MistralAPIKeyVerifier()
    /// Lists the models a key can use; substituted by tests like the verifier.
    @ObservationIgnored
    var mistralModelLister: any MistralModelListing = MistralModelLister()

    // Stops the managed polishd (polishing) process when LLM polishing is turned
    // off in Managed local mode. Kept awaitable so tests can await the shutdown.
    // Shutdown tasks are tracked (never fire-and-forget) so a warmup requested
    // right after a stop can cancel a still-queued stop and serialize behind a
    // running one — otherwise a stale stop lands after the fresh warmup and
    // kills the backend the settings now require.
    @ObservationIgnored
    var polishingShutdownTask: Task<Void, Never>?
    @ObservationIgnored
    var dictationShutdownTask: Task<Void, Never>?
    // Eagerly installs/downloads/starts required managed backends so the user
    // watches inline progress in Settings instead of waiting for dictation.
    // One slot per backend (mirroring BackendManager's per-backend single-flight
    // rationale): a polishing toggle/mode flip must never cancel an in-flight
    // speechd warmup, and vice versa. Kept awaitable for tests.
    @ObservationIgnored
    var dictationWarmupTask: Task<Void, Never>?
    @ObservationIgnored
    var polishingWarmupTask: Task<Void, Never>?

    init(
        settings: SettingsStore,
        backendManager: any ManagedBackendManaging,
        localNetworkPermissionPreflight: any LocalNetworkPermissionPreflighting = LocalNetworkPermissionPreflight()
    ) {
        self.settings = settings
        self.backendManager = backendManager
        self.localNetworkPermissionPreflight = localNetworkPermissionPreflight
    }

    @MainActor
    deinit {
        cancelTasks()
    }

    /// Cancels every warmup and shutdown in flight. Called on the owner's way
    /// out as well, so nothing lands on a backend after the view model is gone.
    func cancelTasks() {
        polishingShutdownTask?.cancel()
        dictationShutdownTask?.cancel()
        dictationWarmupTask?.cancel()
        polishingWarmupTask?.cancel()
    }

    /// The ledger the Usage row sums. The owner wires the same ledger into the
    /// two Mistral request paths it holds.
    func installUsageLedger(_ ledger: MistralUsageLedger) {
        mistralUsageLedger = ledger
    }

    /// A ledger write landed: the Usage row reads the ledger again.
    func noteUsageLedgerChanged() {
        mistralUsageRevision += 1
    }
    func applyDictationBackendModeChange(_ mode: BackendMode) {
        let previousMode = settings.dictationBackendMode
        settings.dictationBackendMode = mode

        if mode == .externalURL {
            preflightDictationEndpoint(reason: "dictation backend switched to external")
        }

        // Every non-managed mode is the same thing to the managed engine: it is
        // not needed. Switching BETWEEN two hosted modes (external ↔ Mistral)
        // therefore starts and stops nothing.
        if !previousMode.isManaged, mode.isManaged {
            startManagedBackendWarmup(dictation: true, polishing: false)
            return
        }

        if previousMode.isManaged, !mode.isManaged {
            Log.backends.info(
                "dictation backend mode switched to \(mode.rawValue, privacy: .public); stopping managed speechd"
            )
            interruptConnectingSession()
            dictationWarmupTask?.cancel()
            dictationShutdownTask?.cancel()
            dictationShutdownTask = Task { @MainActor [backendManager] in
                guard !Task.isCancelled else { return }
                await backendManager.stopDictation()
            }
        }
    }

    func applyPolishingBackendModeChange(_ mode: BackendMode) {
        let previousMode = settings.polishingBackendMode
        settings.polishingBackendMode = mode

        if mode == .externalURL {
            preflightPolishingEndpoint(reason: "polishing backend switched to external")
        }

        if !previousMode.isManaged, mode.isManaged {
            if isManagedPolishingWarmupWanted {
                startPolishingWarmup()
            }
            return
        }

        if previousMode.isManaged, !mode.isManaged {
            Log.backends.info(
                "polishing backend mode switched to \(mode.rawValue, privacy: .public); stopping managed polishd"
            )
            interruptConnectingSession()
            polishingWarmupTask?.cancel()
            polishingShutdownTask?.cancel()
            polishingShutdownTask = Task { @MainActor [backendManager] in
                guard !Task.isCancelled else { return }
                await backendManager.stopPolishing()
            }
        }
    }

    /// One press of "Use Mistral for dictation and polishing": store the key,
    /// move BOTH engines to the hosted API, and turn polishing on — it is the
    /// half of the offer a user cannot see a switch for.
    func applyMistralQuickSetup(apiKey: String) {
        settings.mistralAPIKey = apiKey.trimmed
        Log.backends.info("mistral quick setup requested for dictation and polishing")
        applyDictationBackendModeChange(.mistralAPI)
        applyPolishingBackendModeChange(.mistralAPI)
        settings.llmPolishingEnabled = true
        Log.backends.info(
            "mistral quick setup applied dictation=\(self.settings.dictationBackendMode.rawValue, privacy: .public) polishing=\(self.settings.polishingBackendMode.rawValue, privacy: .public)"
        )
    }

    /// Ask Mistral whether a key works. Returns the verdict rather than storing
    /// it: Settings and the onboarding wizard check different strings and hold
    /// their own state.
    func verifyMistralAPIKey(_ apiKey: String) async -> MistralAPIKeyVerification {
        await mistralAPIKeyVerifier.verify(apiKey: apiKey)
    }

    /// The Engines pane's "Check key" button: checks the STORED key.
    func checkMistralAPIKey() {
        guard !mistralAPIKeyCheckState.isChecking else { return }
        let apiKey = settings.mistralAPIKey
        mistralAPIKeyCheckState = .checking
        mistralAPIKeyCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let verification = await self.verifyMistralAPIKey(apiKey)
            self.mistralAPIKeyCheckState = .finished(verification)
        }
    }

    /// Load the models the stored Mistral key can use into
    /// `settings.mistralModelCatalog`. Once per key: the list changes when
    /// Mistral ships a model, not while Settings is open. A failure keeps the
    /// cached list, so the pickers never empty out over a network blip.
    func refreshMistralModelCatalog(force: Bool = false) {
        let apiKey = settings.trimmedMistralAPIKey
        guard !apiKey.isEmpty else { return }
        guard force || mistralModelListLoadedKey != apiKey else { return }
        mistralModelListTask?.cancel()
        mistralModelListState = .loading
        mistralModelListTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.mistralModelLister.listModels(apiKey: apiKey)
            // Superseded: the newer fetch owns the state.
            guard !Task.isCancelled else { return }
            guard self.settings.trimmedMistralAPIKey == apiKey else {
                // The key changed under the fetch; its list is not this key's.
                self.mistralModelListState = .idle
                return
            }
            switch result {
            case .loaded(let models):
                self.settings.mistralModelCatalog = models
                self.mistralModelListLoadedKey = apiKey
                self.mistralModelListState = .loaded
            case .rejected, .failed:
                self.mistralModelListState = .failed(result)
            }
        }
    }

    func applyRealtimeEndpointChange(_ endpoint: String) {
        settings.realtimeAPIEndpointURL = endpoint
        guard settings.dictationBackendMode == .externalURL else { return }
        preflightDictationEndpoint(reason: "dictation endpoint updated")
    }

    func applyLLMPolishingEndpointChange(_ endpoint: String) {
        settings.llmPolishingEndpointURL = endpoint
        guard settings.polishingBackendMode == .externalURL else { return }
        preflightPolishingEndpoint(reason: "polishing endpoint updated")
    }

    func preflightConfiguredLocalNetworkEndpoints() {
        if settings.dictationBackendMode == .externalURL {
            preflightDictationEndpoint(reason: "configured external dictation endpoint")
        }
        if settings.polishingBackendMode == .externalURL {
            preflightPolishingEndpoint(reason: "configured external polishing endpoint")
        }
    }

    private func preflightDictationEndpoint(reason: String) {
        guard let endpoint = settings.resolvedWebSocketURL(for: settings.realtimeProvider),
              LocalNetworkEndpointPolicy.preflightTarget(for: endpoint) != nil
        else { return }
        localNetworkPermissionPreflight.preflight(endpoint: endpoint, reason: reason)
    }

    private func preflightPolishingEndpoint(reason: String) {
        let configuredEndpoint = settings.llmPolishingEndpointURL.trimmed
        guard settings.polishingBackendMode == .externalURL,
              let endpoint = URL(string: configuredEndpoint),
              LocalNetworkEndpointPolicy.preflightTarget(for: endpoint) != nil
        else { return }
        localNetworkPermissionPreflight.preflight(endpoint: endpoint, reason: reason)
    }

    /// Managed speechd's launch arguments carry this setting; a running engine
    /// keeps its argv, so apply a change by restarting it (same eager UX as
    /// `applyLLMPolishingModelChange`: stop, then warm back up with progress
    /// in the status row). Outside Managed local mode only the stored value
    /// changes — the next managed start reads current settings.
    func applySpeechdCacheLimitChange(_ limit: SpeechdCacheLimit) {
        guard settings.speechdCacheLimit != limit else { return }
        settings.speechdCacheLimit = limit
        restartManagedDictationEngineForSettingChange(reason: "memory limit changed")
    }

    /// See `applySpeechdCacheLimitChange` — same restart contract.
    func applySpeechdStepCadenceChange(_ cadence: SpeechdStepCadence) {
        guard settings.speechdStepCadence != cadence else { return }
        settings.speechdStepCadence = cadence
        restartManagedDictationEngineForSettingChange(reason: "step interval changed")
    }

    private func restartManagedDictationEngineForSettingChange(reason: String) {
        guard settings.dictationBackendMode == .managedLocal else { return }
        Log.backends.info(
            "managed dictation setting changed (\(reason, privacy: .public)); restarting dictation engine"
        )
        dictationWarmupTask?.cancel()
        dictationShutdownTask?.cancel()
        dictationShutdownTask = Task { @MainActor [weak self, backendManager] in
            guard !Task.isCancelled else { return }
            await backendManager.stopDictation()
            guard !Task.isCancelled, let self else { return }
            self.startManagedBackendWarmup(dictation: true, polishing: false)
        }
    }

    func applyLLMPolishingModelChange(_ model: String) {
        guard settings.managedLLMPolishingModel != model else { return }
        settings.managedLLMPolishingModel = model
        guard settings.polishingBackendMode == .managedLocal else { return }

        Log.backends.info("managed polishing model changed; restarting polishing engine")
        polishingWarmupTask?.cancel()
        polishingShutdownTask?.cancel()
        polishingShutdownTask = Task { @MainActor [weak self, backendManager] in
            guard !Task.isCancelled else { return }
            await backendManager.stopPolishing()
            // Same eager UX as the enable/mode toggles: download + relaunch
            // now, with progress in the status row — not on the next
            // dictation (field finding, PR #99 hand-test).
            guard !Task.isCancelled, let self, self.isManagedPolishingWarmupWanted else { return }
            self.startPolishingWarmup()
        }
    }

    func applyDictationOutputModeChange(_ mode: DictationOutputMode) {
        // The menu-bar output mode is not a reachability input (see
        // `isOverlayBufferSessionReachable`), so managed polishd is unaffected.
        settings.dictationOutputMode = mode
    }

    /// Managed polishd follows Overlay Buffer reachability: polishing runs only
    /// on Overlay Buffer commits, so when no trigger can start one the process
    /// is stopped instead of idling in memory.
    func handleOverlayReachabilityTransition(wasReachable: Bool) {
        let isReachable = settings.isOverlayBufferSessionReachable
        guard wasReachable != isReachable,
              settings.llmPolishingEnabled,
              settings.polishingBackendMode == .managedLocal
        else { return }

        if isReachable {
            startPolishingWarmup()
        } else {
            Log.backends.info("no Overlay Buffer trigger configured; stopping managed polishd")
            polishingWarmupTask?.cancel()
            polishingShutdownTask?.cancel()
            polishingShutdownTask = Task { @MainActor [backendManager] in
                guard !Task.isCancelled else { return }
                await backendManager.stopPolishing()
            }
        }
    }

    /// React to the LLM polishing enable toggle. Disabling polishing in Managed
    /// local polishing mode stops the managed polishd process so it stops holding memory.
    /// Enabling in Managed local mode eagerly starts the polishing warmup so
    /// install/model progress is visible in Settings. External URL mode owns
    /// no local process.
    /// Any polish request in flight when the process stops fails, and the
    /// existing polish-failure fallback commits the raw text.
    func llmPolishingEnabledDidChange(_ enabled: Bool) {
        guard settings.polishingBackendMode == .managedLocal else { return }
        polishingShutdownTask?.cancel()
        if enabled, settings.isOverlayBufferSessionReachable {
            startPolishingWarmup()
        } else {
            Log.backends.info("polishing disabled; stopping managed polishd")
            polishingWarmupTask?.cancel()
            polishingShutdownTask = Task { @MainActor [backendManager] in
                guard !Task.isCancelled else { return }
                await backendManager.stopPolishing()
            }
        }
    }

    func warmUpManagedBackendsAtLaunchIfNeeded() {
        guard settings.onboardingCompleted else {
            Log.backends.info("launch managed backend warmup skipped until onboarding completes")
            return
        }

        let needsDictation = settings.dictationBackendMode == .managedLocal
        let needsPolishing = isManagedPolishingWarmupWanted
        startManagedBackendWarmup(dictation: needsDictation, polishing: needsPolishing)
    }

    func startPolishingWarmup() {
        startManagedBackendWarmup(dictation: false, polishing: true)
    }

    // MARK: - Managed model download controls (Engines pane)

    /// Pause the automatic model download, keeping the bytes already fetched.
    /// Parked in the backend's shutdown slot so a Resume (or any other warmup
    /// trigger) serializes behind it, exactly as a stop does.
    func pauseManagedModelDownload(for spec: ManagedBackendSpec) {
        Log.backends.info(
            "model download pause requested from Settings for \(spec.displayName, privacy: .public)"
        )
        runManagedDownloadShutdown(for: spec) { backendManager in
            await backendManager.pauseModelDownload(for: spec)
        }
    }

    /// Cancel the automatic model download and drop the in-flight file's bytes.
    /// Files already in the Hugging Face cache stay; the download restarts on
    /// the next warmup trigger (app launch, an Engines setting change) or on
    /// the next dictation that needs this engine.
    func cancelManagedModelDownload(for spec: ManagedBackendSpec) {
        Log.backends.info(
            "model download cancel requested from Settings for \(spec.displayName, privacy: .public)"
        )
        runManagedDownloadShutdown(for: spec) { backendManager in
            await backendManager.cancelModelDownload(for: spec)
        }
    }

    /// Resume a paused download through the ordinary warmup path, so the
    /// shutdown/warmup serialization that every other trigger relies on holds
    /// here too.
    func resumeManagedModelDownload(for spec: ManagedBackendSpec) {
        let dictation = spec.id == BackendCatalog.speechd.id
        Log.backends.info(
            "model download resume requested from Settings for \(spec.displayName, privacy: .public)"
        )
        startManagedBackendWarmup(dictation: dictation, polishing: !dictation)
    }

    private func runManagedDownloadShutdown(
        for spec: ManagedBackendSpec,
        _ body: @escaping @MainActor (any ManagedBackendManaging) async -> Void
    ) {
        // A dictation session may be sitting on this very download ("Downloading
        // dictation model (42%)..."). Both controls cancel the backend's shared
        // single-flight ensure, which is exactly what that session is awaiting,
        // so retire it here the way a mode switch does — otherwise its await
        // throws, its own task is not cancelled, and the user's Pause is
        // reported back to them as "Managed backend failed".
        interruptConnectingSession()
        if spec.id == BackendCatalog.speechd.id {
            dictationWarmupTask?.cancel()
            dictationShutdownTask?.cancel()
            dictationShutdownTask = Task { @MainActor [backendManager] in
                guard !Task.isCancelled else { return }
                await body(backendManager)
            }
        } else {
            polishingWarmupTask?.cancel()
            polishingShutdownTask?.cancel()
            polishingShutdownTask = Task { @MainActor [backendManager] in
                guard !Task.isCancelled else { return }
                await body(backendManager)
            }
        }
    }

    func startManagedBackendWarmup(dictation: Bool, polishing: Bool) {
        guard dictation || polishing else { return }
        guard settings.onboardingCompleted else {
            Log.backends.info("managed backend warmup skipped until onboarding completes")
            return
        }

        // Owner-specified UX: required managed backends install/download/start
        // eagerly, with progress rendered inline in Engines.
        // Failures land in the manager statuses; dictation-time ensureReady remains the
        // backstop and retry path.
        Log.backends.info(
            "managed backend warmup requested dictation=\(dictation, privacy: .public) polishing=\(polishing, privacy: .public)"
        )
        // A stop decided just before this warmup must not land on the fresh
        // process: cancel the shutdown if it hasn't run yet, and serialize the
        // warmup behind it if it has (rapid managed→external→managed or
        // polishing off→on flips race the async stop otherwise).
        if dictation {
            dictationWarmupTask?.cancel()
            let pendingShutdown = dictationShutdownTask
            dictationShutdownTask = nil
            pendingShutdown?.cancel()
            dictationWarmupTask = Task { @MainActor [backendManager] in
                await pendingShutdown?.value
                try? await backendManager.ensureReady(dictation: true, polishing: false)
            }
        }
        if polishing {
            polishingWarmupTask?.cancel()
            let pendingShutdown = polishingShutdownTask
            polishingShutdownTask = nil
            pendingShutdown?.cancel()
            polishingWarmupTask = Task { @MainActor [backendManager] in
                await pendingShutdown?.value
                try? await backendManager.ensureReady(dictation: false, polishing: true)
            }
        }
    }

    /// Writes a local-first diagnostics report to the Desktop. The report
    /// contains only non-secret configuration/status (no API keys, no dictated
    /// content). See `DiagnosticsExporter` for the redaction boundary.
    func exportDiagnostics() {
        let snapshot = DiagnosticsExporter.makeSnapshot(
            settings: settings,
            speechdStatus: backendManager.speechdStatus,
            polishdStatus: backendManager.polishdStatus,
            speechdRecentOutput: backendManager.recentOutput(for: BackendCatalog.speechd),
            polishdRecentOutput: backendManager.recentOutput(for: BackendCatalog.polishd)
        )

        guard let desktop = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        ).first else {
            Log.diagnostics.error("diagnostics export failed: Desktop directory unavailable")
            return
        }

        let exportedAt = Date()
        Task.detached(priority: .utility) {
            do {
                let writtenURL = try DiagnosticsExporter.writeReport(
                    snapshot: snapshot,
                    to: desktop,
                    now: exportedAt
                )
                Log.diagnostics.info("diagnostics exported: \(writtenURL.path, privacy: .public)")
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([writtenURL])
                }
            } catch {
                Log.diagnostics.error("diagnostics export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Warmup-time variant of `isManagedPolishingRequired`: instead of a
    /// session's output mode, gates on whether a keyboard trigger can start
    /// an Overlay Buffer session at all. When false, managed polishd stays
    /// stopped — an overlay session started from the menu-bar button still
    /// polishes via the dictation-time `ensureReady` backstop, paying the
    /// polishd cold start (deliberate: see
    /// `SettingsStore.isOverlayBufferSessionReachable`).
    var isManagedPolishingWarmupWanted: Bool {
        settings.llmPolishingEnabled
            && settings.polishingBackendMode == .managedLocal
            && settings.isOverlayBufferSessionReachable
    }
}
