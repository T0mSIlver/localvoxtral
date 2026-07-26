import Foundation

/// Warms the managed polishing helper's prompt-prefix cache right after it
/// becomes ready, so the FIRST real polish request of a helper launch does
/// not pay the full static-prefix prefill (with the 4B default that prefill
/// is the dominant share of first-polish latency).
///
/// Why app-side: `localvoxtral-polishd` keeps KV-state checkpoints of the
/// templated stable prefix — every message except the last — keyed by the
/// exact prefix tokens plus chat-template kwargs, one LRU slot per prompt
/// profile (`MLXPolishModel` / `PromptPrefixSlotStore`). The app, not the
/// helper, knows the prompt templates, and every production polish request
/// of a given profile shares that profile's `[system, static user prefix]`
/// head (the rendered user prompt is split at its first placeholder —
/// `LLMPromptTemplates.renderedUserPrompts`). One request per profile
/// through the production request path with that head and a throwaway tail
/// therefore checkpoints exactly the state real requests reuse.
enum PolishPromptWarmup {
    /// Throwaway final-message content. Its text never matters for cache
    /// reuse — only the preceding messages are checkpointed — it just has to
    /// be non-empty (the service rejects empty input).
    static let warmupInputText = "Ready."

    /// The warmup request: identical prefix messages to a production polish
    /// request (same system prompt, same static user prefix, dictionary slot
    /// rides the dynamic tail), minimal tail, and a 1-token generation cap.
    static func request(templates: LLMPromptTemplates) -> LLMPolishingRequest {
        LLMPolishingRequest(
            inputText: warmupInputText,
            systemPrompt: templates.systemContent,
            userPrompts: templates.renderedUserPrompts(
                inputText: warmupInputText,
                replacementDictionary: ""
            ),
            maxTokens: 1
        )
    }

    /// The warmups to run for the current settings, or nil when warmup must
    /// not run: polishing disabled, or the polishing backend is an external
    /// URL (never warm someone else's server — and its cache keying is
    /// unknown anyway).
    ///
    /// One request per prompt profile a commit could use: the standard
    /// profile always, plus the agent profile when its toggle is on — the
    /// helper keeps one prefix-checkpoint slot per profile
    /// (`--prompt-cache-slots`, default 2), so warming both keeps the first
    /// polish fast whichever app the user dictates into. When the agent
    /// prompt files fall back to the standard templates (corrupt/missing —
    /// see `loadLLMPromptTemplates(profile:)`), the prefixes are identical
    /// and the duplicate request is dropped.
    @MainActor
    static func plan(
        settings: SettingsStore,
        appConfigStore: any AppConfigServing
    ) -> (requests: [ProfiledRequest], configuration: LLMPolishingConfiguration)? {
        guard settings.polishingBackendMode == .managedLocal,
            let configuration = settings.llmPolishingConfiguration
        else {
            return nil
        }
        let standardRequest = request(templates: appConfigStore.loadLLMPromptTemplates())
        var requests: [ProfiledRequest] = [
            ProfiledRequest(profile: .standard, request: standardRequest)
        ]
        if settings.agentPolishProfileEnabled {
            let agentRequest = request(
                templates: appConfigStore.loadLLMPromptTemplates(profile: .agent)
            )
            if !sharesCheckpointedPrefix(agentRequest, standardRequest) {
                requests.append(ProfiledRequest(profile: .agent, request: agentRequest))
            }
        }
        return (requests, configuration)
    }

    /// Whether two warmup requests would prime the same helper checkpoint.
    /// The helper's cache key is the templated NON-FINAL messages (system +
    /// all user prompts but the last), so the comparison mirrors exactly
    /// that — templates that differ only past the first placeholder (or an
    /// agent fallback to the standard files) share one checkpoint, and the
    /// duplicate request would be wasted helper work.
    private static func sharesCheckpointedPrefix(
        _ lhs: LLMPolishingRequest,
        _ rhs: LLMPolishingRequest
    ) -> Bool {
        lhs.systemPrompt == rhs.systemPrompt
            && lhs.userPrompts.dropLast() == rhs.userPrompts.dropLast()
    }

    /// A warmup request labeled with the profile it primes, so per-request
    /// log lines can attribute a slow or failed warmup to the right prefix.
    struct ProfiledRequest {
        let profile: PolishPromptProfile
        let request: LLMPolishingRequest
    }
}

/// Fires one prompt-prefix warmup per managed-helper launch by edge-detecting
/// the polishd status stream: a transition into `.ready` from any non-ready
/// status is a (re)launch with a cold cache — initial start, crash
/// auto-restart, model-switch restart, or polishing re-enable. The duplicate
/// `.ready` that `BackendManager.ensureReady` re-emits on every dictation
/// start is NOT an edge, so warmup never fires per dictation.
///
/// The warmup task is fire-and-forget: nothing in the session path ever
/// awaits it, so it cannot delay a real polish request app-side. Helper-side
/// warmup and real requests serialize on the model container; with
/// `max_tokens: 1` each warmup's tail work past the (wanted) prefix prefill
/// is a few tail tokens plus one generated token. The plan's per-profile
/// requests run sequentially in one task (the container would serialize them
/// anyway), a non-cancellation failure on one profile still warms the rest,
/// and failures are logged to `Log.backends` and swallowed — warmup is never
/// user-visible.
@MainActor
final class PolishPromptWarmupCoordinator {
    typealias PlanProvider =
        @MainActor () -> (
            requests: [PolishPromptWarmup.ProfiledRequest],
            configuration: LLMPolishingConfiguration
        )?
    typealias ServiceProvider = @MainActor () -> any LLMPolishingServicing

    private let serviceProvider: ServiceProvider
    private let planProvider: PlanProvider
    private var polishdWasReady = false
    private var observationTask: Task<Void, Never>?
    /// Kept awaitable for tests (same convention as the view model's
    /// warmup/shutdown task slots).
    private(set) var warmupTask: Task<Void, Never>?

    init(
        serviceProvider: @escaping ServiceProvider,
        planProvider: @escaping PlanProvider
    ) {
        self.serviceProvider = serviceProvider
        self.planProvider = planProvider
    }

    /// Consumes a `BackendManager.statusUpdates` subscription for the process
    /// lifetime. Call at most once.
    func observe(_ updates: AsyncStream<ManagedBackendStatusUpdate>) {
        precondition(observationTask == nil, "PolishPromptWarmupCoordinator.observe called twice")
        observationTask = Task { @MainActor [weak self] in
            for await update in updates {
                guard let self else { return }
                self.handleStatusUpdate(update)
            }
        }
    }

    func cancelTasks() {
        observationTask?.cancel()
        warmupTask?.cancel()
    }

    func handleStatusUpdate(_ update: ManagedBackendStatusUpdate) {
        guard update.spec.id == BackendCatalog.polishd.id else { return }
        let isReady = update.status == .ready
        defer { polishdWasReady = isReady }
        if !isReady {
            // The helper this warmup targeted is stopping/restarting; its
            // cache dies with it. The next ready edge starts a fresh warmup.
            warmupTask?.cancel()
            return
        }
        guard !polishdWasReady else { return }
        startWarmup()
    }

    private func startWarmup() {
        guard let plan = planProvider() else {
            Log.backends.info(
                "polish prompt warmup skipped (polishing disabled or backend not managed)"
            )
            return
        }
        warmupTask?.cancel()
        let profiles = plan.requests.map(\.profile.rawValue).joined(separator: "+")
        Log.backends.info(
            "polish prompt warmup started for model \(plan.configuration.model, privacy: .public) profiles \(profiles, privacy: .public)"
        )
        let service = serviceProvider()
        warmupTask = Task { @MainActor in
            for profiledRequest in plan.requests {
                // Checked per iteration, not only on the error path: a helper
                // stop can race a SUCCESSFUL response, and the next profile's
                // request must not land on the stopped (or replacement)
                // helper.
                guard !Task.isCancelled else {
                    Log.backends.info("polish prompt warmup cancelled")
                    return
                }
                let profile = profiledRequest.profile.rawValue
                do {
                    let result = try await service.polish(
                        request: profiledRequest.request,
                        configuration: plan.configuration
                    )
                    Log.backends.info(
                        "polish prompt warmup (\(profile, privacy: .public)) completed in \(String(format: "%.2f", result.durationSeconds), privacy: .public)s"
                    )
                } catch is CancellationError {
                    Log.backends.info("polish prompt warmup cancelled")
                    return
                } catch {
                    guard !Task.isCancelled else {
                        Log.backends.info("polish prompt warmup cancelled")
                        return
                    }
                    // Log-only by design: the helper may still have prefilled
                    // the prefix (e.g. a client-side timeout), and the next
                    // real request works either way — it just pays full
                    // prefill. The remaining profiles still get their warmup.
                    Log.backends.error(
                        "polish prompt warmup (\(profile, privacy: .public)) failed (log-only): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }
}
