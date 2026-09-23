import Foundation
import Observation

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
        let speakerProfile = settings.polishSpeakerProfile
        let speakerTerms = settings.polishSpeakerTerms
        let standardRequest = request(
            templates: appConfigStore.loadLLMPromptTemplates()
                .withSpeakerProfile(speakerProfile, terms: speakerTerms)
        )
        var requests: [ProfiledRequest] = [
            ProfiledRequest(profile: .standard, request: standardRequest)
        ]
        if settings.agentPolishProfileEnabled {
            let agentRequest = request(
                templates: appConfigStore.loadLLMPromptTemplates(profile: .agent)
                    .withSpeakerProfile(speakerProfile, terms: speakerTerms)
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

    /// What the helper keys a prefix checkpoint on, seen from the app: the
    /// non-final messages plus everything in the configuration that changes
    /// how they are templated or where they go.
    struct CachedPrefix: Hashable {
        let systemPrompt: String
        let prefixUserPrompts: [String]
        let endpoint: String
        let model: String
        let chatTemplateArguments: [String: Bool]?

        init(request: LLMPolishingRequest, configuration: LLMPolishingConfiguration) {
            systemPrompt = request.systemPrompt
            prefixUserPrompts = Array(request.userPrompts.dropLast())
            endpoint = configuration.endpointURL.absoluteString
            model = configuration.model
            chatTemplateArguments = configuration.chatTemplateArguments
        }
    }

    /// A warmup request labeled with the profile it primes, so per-request
    /// log lines can attribute a slow or failed warmup to the right prefix.
    struct ProfiledRequest {
        let profile: PolishPromptProfile
        let request: LLMPolishingRequest
    }
}

/// Keeps the managed helper's prompt-prefix cache warm for every prefix the
/// current settings would send, so no dictation ends on a cold cache.
///
/// The coordinator remembers which prefixes it warmed on the current helper
/// launch (`PolishPromptWarmup.CachedPrefix`) and warms whatever the current
/// plan needs that is not in that set. It reconciles on three triggers:
/// - every polishd `.ready` update. A launch clears the set (initial start,
///   crash auto-restart, model-switch restart, polishing re-enable); the
///   duplicate `.ready` that `ensureReady` re-emits finds nothing missing.
/// - a change to any setting the plan reads (About you, speaker terms, the
///   agent toggle, the model and its template arguments), observed through
///   `withObservationTracking` and settled for `settleDelay` on the injected
///   clock so a burst of keystrokes warms once.
/// - a dictation start (`ensureWarm`), which catches what observation cannot
///   see: a prompt TOML edited on disk.
///
/// The warmup task is fire-and-forget: nothing in the session path ever
/// awaits it, so it cannot delay a real polish request app-side. Helper-side
/// warmup and real requests serialize on the model container; with
/// `max_tokens: 1` each warmup's tail work past the (wanted) prefix prefill
/// is a few tail tokens plus one generated token. The plan's per-profile
/// requests run sequentially in one task (the container would serialize them
/// anyway), a non-cancellation failure on one profile still warms the rest,
/// and failures are logged to `Log.backends` and swallowed — warmup is never
/// user-visible. A failed prefix stays missing, so the next trigger retries it.
@MainActor
final class PolishPromptWarmupCoordinator {
    typealias PlanProvider =
        @MainActor () -> (
            requests: [PolishPromptWarmup.ProfiledRequest],
            configuration: LLMPolishingConfiguration
        )?
    typealias ServiceProvider = @MainActor () -> any LLMPolishingServicing

    /// How long plan inputs must stay unchanged before a settings-driven
    /// warmup runs: long enough to cover typing in the About-you field.
    static let defaultSettleDelay: Duration = .milliseconds(1500)

    private let serviceProvider: ServiceProvider
    private let planProvider: PlanProvider
    private let clock: SessionClock
    private let settleDelay: Duration
    private var polishdIsReady = false
    /// Prefixes the current helper launch holds because a warmup succeeded.
    private var warmedPrefixes: Set<PolishPromptWarmup.CachedPrefix> = []
    /// Prefixes the running `warmupTask` has not finished yet, in order; each
    /// leaves the list when its request completes.
    private var inFlightPrefixes: [PolishPromptWarmup.CachedPrefix] = []
    /// Bumped per warmup task, so a superseded task's late completion cannot
    /// mark a prefix warm for a helper launch it did not target.
    private var warmupGeneration = 0
    private var observationTask: Task<Void, Never>?
    private var isObservingPlanInputs = false
    /// Kept awaitable for tests (same convention as the view model's
    /// warmup/shutdown task slots).
    private(set) var warmupTask: Task<Void, Never>?
    private(set) var settleTask: Task<Void, Never>?

    init(
        serviceProvider: @escaping ServiceProvider,
        planProvider: @escaping PlanProvider,
        clock: SessionClock = .live,
        settleDelay: Duration = PolishPromptWarmupCoordinator.defaultSettleDelay
    ) {
        self.serviceProvider = serviceProvider
        self.planProvider = planProvider
        self.clock = clock
        self.settleDelay = settleDelay
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

    /// Re-warms after any `@Observable` state the plan reads changes. Call at
    /// most once; the observation re-arms itself after every change.
    func observePlanInputs() {
        guard !isObservingPlanInputs else { return }
        isObservingPlanInputs = true
        armPlanObservation()
    }

    func cancelTasks() {
        observationTask?.cancel()
        warmupTask?.cancel()
        settleTask?.cancel()
        isObservingPlanInputs = false
    }

    func handleStatusUpdate(_ update: ManagedBackendStatusUpdate) {
        guard update.spec.id == BackendCatalog.polishd.id else { return }
        guard update.status == .ready else {
            // The helper this warmup targeted is stopping/restarting; its
            // cache dies with it. The next ready update warms from scratch.
            if polishdIsReady || warmupTask != nil {
                warmupTask?.cancel()
                warmupTask = nil
                inFlightPrefixes = []
            }
            warmedPrefixes = []
            polishdIsReady = false
            return
        }
        let isLaunch = !polishdIsReady
        polishdIsReady = true
        ensureWarm(reason: isLaunch ? "helper ready" : "helper ready again")
    }

    /// Warms every prefix of the current plan this helper launch does not
    /// hold yet. Cheap when everything is warm: it computes the plan and
    /// returns. Called on a dictation start and by the other triggers.
    func ensureWarm(reason: String) {
        settleTask?.cancel()
        settleTask = nil
        guard polishdIsReady else { return }
        guard let plan = planProvider() else {
            if warmupTask != nil {
                warmupTask?.cancel()
                warmupTask = nil
                inFlightPrefixes = []
            }
            Log.backends.info(
                "polish prompt warmup skipped on \(reason, privacy: .public) (polishing disabled or backend not managed)"
            )
            return
        }
        let planned = plan.requests.map {
            (profiled: $0, prefix: PolishPromptWarmup.CachedPrefix(
                request: $0.request, configuration: plan.configuration))
        }
        // Only the current plan's prefixes count as warm: the helper keeps a
        // few LRU slots, and a prefix from before a settings change may have
        // been evicted by the time the setting changes back.
        warmedPrefixes.formIntersection(planned.map(\.prefix))
        let missing = planned.filter { !warmedPrefixes.contains($0.prefix) }
        guard !missing.isEmpty else {
            // Whatever is still in flight is no longer planned (a profile
            // turned off, an edit reverted): it would only hold the helper
            // ahead of a real polish.
            if warmupTask != nil {
                warmupTask?.cancel()
                warmupTask = nil
                inFlightPrefixes = []
            }
            return
        }
        if warmupTask != nil, inFlightPrefixes == missing.map(\.prefix) { return }

        warmupTask?.cancel()
        warmupGeneration += 1
        let generation = warmupGeneration
        inFlightPrefixes = missing.map(\.prefix)
        let profiles = missing.map(\.profiled.profile.rawValue).joined(separator: "+")
        Log.backends.info(
            "polish prompt warmup started on \(reason, privacy: .public) for model \(plan.configuration.model, privacy: .public) profiles \(profiles, privacy: .public)"
        )
        let service = serviceProvider()
        let configuration = plan.configuration
        warmupTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.warmupGeneration == generation {
                    self.inFlightPrefixes = []
                    self.warmupTask = nil
                }
            }
            for entry in missing {
                // Checked per iteration, not only on the error path: a helper
                // stop can race a SUCCESSFUL response, and the next profile's
                // request must not land on the stopped (or replacement)
                // helper.
                guard !Task.isCancelled else {
                    Log.backends.info("polish prompt warmup cancelled")
                    return
                }
                let profile = entry.profiled.profile.rawValue
                defer {
                    if let self, self.warmupGeneration == generation,
                        self.inFlightPrefixes.first == entry.prefix
                    {
                        self.inFlightPrefixes.removeFirst()
                    }
                }
                do {
                    let result = try await service.polish(
                        request: entry.profiled.request,
                        configuration: configuration
                    )
                    guard !Task.isCancelled else {
                        Log.backends.info("polish prompt warmup cancelled")
                        return
                    }
                    self?.warmedPrefixes.insert(entry.prefix)
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
                    // prefill. The prefix stays missing, so the next trigger
                    // retries it; the remaining profiles still get theirs.
                    Log.backends.error(
                        "polish prompt warmup (\(profile, privacy: .public)) failed (log-only): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    private func armPlanObservation() {
        guard isObservingPlanInputs else { return }
        withObservationTracking {
            _ = planProvider()
        } onChange: { [weak self] in
            // Fires on willSet, before the new value is readable, and once
            // per arming: hop to the main actor, re-arm, then settle.
            Task { @MainActor in
                self?.planInputsChanged()
            }
        }
    }

    private func planInputsChanged() {
        armPlanObservation()
        settleTask?.cancel()
        let clock = clock
        let settleDelay = settleDelay
        settleTask = Task { @MainActor [weak self] in
            await clock.sleep(settleDelay)
            guard !Task.isCancelled, let self else { return }
            self.settleTask = nil
            self.ensureWarm(reason: "settings change")
        }
    }
}
