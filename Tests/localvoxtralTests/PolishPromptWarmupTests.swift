import Foundation
import XCTest

@testable import localvoxtral

@MainActor
final class PolishPromptWarmupTests: XCTestCase {
    // MARK: - Fakes

    private final class LockedBool: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Bool

        init(_ value: Bool) { storage = value }

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func set(_ value: Bool) {
            lock.lock()
            storage = value
            lock.unlock()
        }
    }

    /// Records polish calls and answers from a configurable result. Locked,
    /// not actor-based, matching the repo's locked-fake convention.
    private final class RecordingPolishService: LLMPolishingServicing, @unchecked Sendable {
        private let lock = NSLock()
        private var recordedRequests: [LLMPolishingRequest] = []
        private var failure: Error?

        func setFailure(_ error: Error?) {
            lock.lock()
            failure = error
            lock.unlock()
        }

        var requests: [LLMPolishingRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }

        func polish(
            request: LLMPolishingRequest,
            configuration: LLMPolishingConfiguration
        ) async throws -> LLMPolishingResult {
            let pendingFailure: Error? = lock.withLock {
                recordedRequests.append(request)
                return failure
            }
            if let pendingFailure {
                throw pendingFailure
            }
            return LLMPolishingResult(
                rawText: request.inputText,
                polishedText: request.inputText,
                durationSeconds: 0
            )
        }
    }

    /// Suspends inside polish() until the surrounding task is cancelled —
    /// event-driven (continuation resumed by the cancellation handler), no
    /// wall-clock waiting.
    private final class SuspendingPolishService: LLMPolishingServicing, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var cancellationObserved = false
        let started = XCTestExpectation(description: "polish request reached the service")

        var observedCancellation: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancellationObserved
        }

        func polish(
            request: LLMPolishingRequest,
            configuration: LLMPolishingConfiguration
        ) async throws -> LLMPolishingResult {
            started.fulfill()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    self.continuation = continuation
                    lock.unlock()
                }
            } onCancel: {
                lock.lock()
                cancellationObserved = true
                let continuation = self.continuation
                self.continuation = nil
                lock.unlock()
                continuation?.resume(throwing: CancellationError())
            }
            return LLMPolishingResult(rawText: "", polishedText: "", durationSeconds: 0)
        }
    }

    /// First polish call suspends, and resolves SUCCESSFULLY when the
    /// surrounding task is cancelled — models a helper response that wins
    /// the race against cancellation. Later calls answer immediately.
    private final class SucceedOnCancelPolishService: LLMPolishingServicing, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var recordedRequests: [LLMPolishingRequest] = []
        let started = XCTestExpectation(description: "first polish request reached the service")

        var requests: [LLMPolishingRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }

        func polish(
            request: LLMPolishingRequest,
            configuration: LLMPolishingConfiguration
        ) async throws -> LLMPolishingResult {
            let isFirst: Bool = lock.withLock {
                recordedRequests.append(request)
                return recordedRequests.count == 1
            }
            if isFirst {
                started.fulfill()
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        lock.lock()
                        self.continuation = continuation
                        lock.unlock()
                    }
                } onCancel: {
                    lock.lock()
                    let continuation = self.continuation
                    self.continuation = nil
                    lock.unlock()
                    continuation?.resume()
                }
            }
            return LLMPolishingResult(
                rawText: request.inputText,
                polishedText: request.inputText,
                durationSeconds: 0
            )
        }
    }

    // MARK: - Helpers

    private func makePlan(
        profiles: [PolishPromptProfile] = [.standard]
    ) -> (
        requests: [PolishPromptWarmup.ProfiledRequest],
        configuration: LLMPolishingConfiguration
    ) {
        (
            requests: profiles.map { profile in
                PolishPromptWarmup.ProfiledRequest(
                    profile: profile,
                    request: LLMPolishingRequest(
                        inputText: "warm",
                        systemPrompt: "system \(profile.rawValue)",
                        userPrompts: ["static prefix \(profile.rawValue)", "tail"],
                        maxTokens: 1
                    )
                )
            },
            configuration: LLMPolishingConfiguration(
                endpointURL: URL(string: "http://127.0.0.1:9/v1/chat/completions")!,
                apiKey: "",
                model: "test-model"
            )
        )
    }

    private func update(
        _ spec: ManagedBackendSpec,
        _ status: ManagedBackendStatus
    ) -> ManagedBackendStatusUpdate {
        ManagedBackendStatusUpdate(spec: spec, status: status)
    }

    private func awaitWarmup(_ coordinator: PolishPromptWarmupCoordinator) async {
        await coordinator.warmupTask?.value
    }

    // MARK: - Trigger logic

    func testWarmupFiresOnReadyEdgeButNotOnDuplicateReady() async {
        let service = RecordingPolishService()
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan()] in plan }
        )

        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .starting))
        XCTAssertNil(coordinator.warmupTask, "warmup must not fire before ready")

        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.count, 1)
        XCTAssertEqual(service.requests.first?.maxTokens, 1)

        // ensureReady re-emits .ready on every dictation start — NOT a new
        // helper launch, must not re-warm.
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.count, 1, "duplicate ready must not re-fire warmup")
    }

    func testTwoProfilePlanWarmsBothPrefixesPerReadyEdge() async {
        let service = RecordingPolishService()
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan(profiles: [.standard, .agent])] in plan }
        )

        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(
            service.requests.map(\.systemPrompt),
            ["system standard", "system agent"],
            "one ready edge must warm every profile's prefix, standard first"
        )

        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.count, 2, "duplicate ready must not re-fire warmup")
    }

    func testFirstProfileFailureStillWarmsRemainingProfiles() async {
        // A non-cancellation failure is log-only per profile: the agent
        // request must still be sent when the standard one failed.
        let service = RecordingPolishService()
        service.setFailure(LLMPolishingError.networkError("connection refused"))
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan(profiles: [.standard, .agent])] in plan }
        )

        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.count, 2)
    }

    func testHelperStopAfterSuccessfulFirstProfileSkipsRemainingProfiles() async {
        // Codex review finding: cancellation was only observed on the error
        // path, so a helper stop racing a SUCCESSFUL standard response let
        // the agent request land on the stopped (or replacement) helper.
        let service = SucceedOnCancelPolishService()
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan(profiles: [.standard, .agent])] in plan }
        )

        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await fulfillment(of: [service.started], timeout: 5)
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .stopped))
        await awaitWarmup(coordinator)
        XCTAssertEqual(
            service.requests.count, 1,
            "a cancelled warmup must not start the next profile's request"
        )
    }

    func testWarmupFiresAgainAfterHelperRestart() async {
        let service = RecordingPolishService()
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan()] in plan }
        )

        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.count, 1)

        // Model switch / polishing toggle: stopped then relaunched.
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .stopped))
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.count, 2)

        // Crash auto-restart: the supervisor mirrors .restarting as .starting
        // before the fresh .ready.
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .starting))
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.count, 3)
    }

    func testWarmupIgnoresSpeechdUpdates() async {
        let service = RecordingPolishService()
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan()] in plan }
        )

        coordinator.handleStatusUpdate(update(BackendCatalog.speechd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertTrue(service.requests.isEmpty)

        // A speechd non-ready update must not reset polishd's edge state.
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        coordinator.handleStatusUpdate(update(BackendCatalog.speechd, .stopped))
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.count, 1)
    }

    func testWarmupSkippedWhenPlanProviderDeclines() async {
        // The plan provider returns nil for "polishing disabled" and
        // "external endpoint" (see PolishPromptWarmupPlanTests) — the
        // coordinator must not fire a request in that case, and must warm
        // normally once a later launch has a plan.
        let service = RecordingPolishService()
        let planAvailable = LockedBool(false)
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan()] in planAvailable.value ? plan : nil }
        )

        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertNil(coordinator.warmupTask)
        XCTAssertTrue(service.requests.isEmpty)

        planAvailable.set(true)
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .stopped))
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.count, 1)
    }

    func testWarmupFailureIsSwallowedAndNextLaunchWarmsAgain() async {
        let service = RecordingPolishService()
        service.setFailure(LLMPolishingError.networkError("connection refused"))
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan()] in plan }
        )

        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.count, 1)

        // The failure is log-only; the next helper launch warms again.
        service.setFailure(nil)
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .stopped))
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.count, 2)
    }

    func testHelperStopCancelsInFlightWarmup() async {
        let service = SuspendingPolishService()
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan()] in plan }
        )

        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await fulfillment(of: [service.started], timeout: 5)

        // The helper this warmup targeted is going away — the request must
        // be cancelled, not left to land on (or race) the next launch.
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .stopped))
        await awaitWarmup(coordinator)
        XCTAssertTrue(service.observedCancellation)
    }

    // MARK: - Warmup request shape (the cache-hit invariant)

    /// The invariant that makes app-side warmup work: the helper checkpoints
    /// every message EXCEPT the last, so the warmup request's non-final
    /// messages must be byte-identical to a production polish request's,
    /// whatever the transcript or dictionary content.
    func testWarmupRequestSharesAllNonFinalMessagesWithProductionRequests() throws {
        let (templates, cleanup) = try LLMPolishEvalSupport.defaultPromptTemplates()
        defer { cleanup() }

        let warmup = PolishPromptWarmup.request(templates: templates)
        let production = LLMPolishingRequest(
            inputText: "fix the bug in src/auth/useAuth.ts , then run the tests .",
            systemPrompt: templates.systemContent,
            userPrompts: templates.renderedUserPrompts(
                inputText: "fix the bug in src/auth/useAuth.ts , then run the tests .",
                replacementDictionary: "- \"local vox\" -> \"localvoxtral\""
            )
        )

        XCTAssertEqual(warmup.systemPrompt, production.systemPrompt)
        XCTAssertEqual(warmup.userPrompts.count, production.userPrompts.count)
        XCTAssertEqual(
            Array(warmup.userPrompts.dropLast()),
            Array(production.userPrompts.dropLast()),
            "warmup must prime the exact prefix messages production requests reuse"
        )
        XCTAssertEqual(warmup.maxTokens, 1)
        XCTAssertFalse(
            warmup.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the service rejects empty input"
        )
    }

    /// Same invariant for the agent profile's bundled templates: an agent
    /// commit reuses the checkpoint only if the warmup's non-final messages
    /// are byte-identical to an agent production request's.
    func testWarmupRequestSharesAllNonFinalMessagesWithAgentProductionRequests() throws {
        let (templates, cleanup) = try LLMPolishEvalSupport.agentPromptTemplates()
        defer { cleanup() }

        let warmup = PolishPromptWarmup.request(templates: templates)
        let production = LLMPolishingRequest(
            inputText: "run cargo test dash dash release",
            systemPrompt: templates.systemContent,
            userPrompts: templates.renderedUserPrompts(
                inputText: "run cargo test dash dash release",
                replacementDictionary: ""
            )
        )

        XCTAssertEqual(warmup.systemPrompt, production.systemPrompt)
        XCTAssertEqual(warmup.userPrompts.count, production.userPrompts.count)
        XCTAssertEqual(
            Array(warmup.userPrompts.dropLast()),
            Array(production.userPrompts.dropLast()),
            "warmup must prime the exact prefix messages agent production requests reuse"
        )
    }

    /// A custom user template with no static text before its first
    /// placeholder renders as a single user message; the shared prefix is
    /// then just the system message, and warmup must mirror that shape.
    func testWarmupRequestMatchesSingleMessageTemplates() {
        let templates = LLMPromptTemplates(
            systemContent: "You fix punctuation.",
            userContent: "{{input_text}}"
        )

        let warmup = PolishPromptWarmup.request(templates: templates)
        let production = templates.renderedUserPrompts(
            inputText: "any transcript",
            replacementDictionary: ""
        )

        XCTAssertEqual(warmup.systemPrompt, "You fix punctuation.")
        XCTAssertEqual(warmup.userPrompts.count, production.count)
        XCTAssertEqual(warmup.userPrompts, [PolishPromptWarmup.warmupInputText])
    }
}

@MainActor
final class PolishPromptWarmupPlanTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuiteName = "localvoxtral.PolishPromptWarmupPlanTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        self.defaults = defaults
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = ""
        try await super.tearDown()
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults, environment: [:])
    }

    /// Implements only the zero-arg loader, so the protocol's default
    /// conformance answers every profile with the standard templates —
    /// exactly the agent-file-fallback shape of the real store.
    private var configStore: some AppConfigServing {
        struct Fixed: AppConfigServing {
            func configDirectoryURL() -> URL { URL(fileURLWithPath: "/dev/null") }
            func loadReplacementDictionary() -> ReplacementDictionary {
                ReplacementDictionary(entries: [])
            }
            func loadLLMPromptTemplates() -> LLMPromptTemplates {
                LLMPromptTemplates(systemContent: "system", userContent: "prefix {{input_text}}")
            }
            func loadTerminalAppBundleIDs() -> [String] { [] }
        }
        return Fixed()
    }

    /// Distinct templates per profile, like the real store with healthy
    /// agent prompt files.
    private var profileAwareConfigStore: some AppConfigServing {
        struct ProfileAware: AppConfigServing {
            func configDirectoryURL() -> URL { URL(fileURLWithPath: "/dev/null") }
            func loadReplacementDictionary() -> ReplacementDictionary {
                ReplacementDictionary(entries: [])
            }
            func loadLLMPromptTemplates() -> LLMPromptTemplates {
                LLMPromptTemplates(systemContent: "system", userContent: "prefix {{input_text}}")
            }
            func loadLLMPromptTemplates(profile: PolishPromptProfile) -> LLMPromptTemplates {
                switch profile {
                case .standard:
                    return loadLLMPromptTemplates()
                case .agent:
                    return LLMPromptTemplates(
                        systemContent: "agent system",
                        userContent: "agent prefix {{input_text}}"
                    )
                }
            }
            func loadTerminalAppBundleIDs() -> [String] { [] }
        }
        return ProfileAware()
    }

    func testPlanWarmsManagedEndpointWhenPolishingEnabled() throws {
        let store = makeStore()
        store.llmPolishingEnabled = true

        let plan = try XCTUnwrap(
            PolishPromptWarmup.plan(settings: store, appConfigStore: configStore)
        )

        XCTAssertEqual(
            plan.configuration.endpointURL.absoluteString,
            ManagedBackendEndpoints.polishingURLString
        )
        XCTAssertEqual(plan.requests.first?.request.maxTokens, 1)
    }

    /// Regression (first agent-profile polish paid full cold prefill): with
    /// the agent profile enabled and healthy agent prompt files, the plan
    /// must warm the AGENT prefix too — the helper keeps one checkpoint slot
    /// per profile, and a standard-only warmup leaves the terminal-dictation
    /// first polish cold.
    func testPlanWarmsAgentPrefixWhenAgentProfileEnabled() throws {
        let store = makeStore()
        store.llmPolishingEnabled = true
        store.agentPolishProfileEnabled = true

        let plan = try XCTUnwrap(
            PolishPromptWarmup.plan(settings: store, appConfigStore: profileAwareConfigStore)
        )

        XCTAssertEqual(plan.requests.map(\.profile), [.standard, .agent])
        let agentRequest = try XCTUnwrap(plan.requests.last?.request)
        XCTAssertEqual(agentRequest.systemPrompt, "agent system")
        XCTAssertEqual(agentRequest.userPrompts.first, "agent prefix ")
        XCTAssertEqual(agentRequest.maxTokens, 1)
    }

    func testPlanSkipsAgentPrefixWhenProfileDisabled() throws {
        let store = makeStore()
        store.llmPolishingEnabled = true
        store.agentPolishProfileEnabled = false

        let plan = try XCTUnwrap(
            PolishPromptWarmup.plan(settings: store, appConfigStore: profileAwareConfigStore)
        )

        XCTAssertEqual(plan.requests.map(\.profile), [.standard])
    }

    func testPlanDropsDuplicateAgentRequestOnTemplateFallback() throws {
        // Agent prompt files corrupt/missing → the loader answers with the
        // standard templates; warming the identical prefix twice is wasted
        // helper work, so the plan de-duplicates it.
        let store = makeStore()
        store.llmPolishingEnabled = true
        store.agentPolishProfileEnabled = true

        let plan = try XCTUnwrap(
            PolishPromptWarmup.plan(settings: store, appConfigStore: configStore)
        )

        XCTAssertEqual(plan.requests.map(\.profile), [.standard])
    }

    func testPlanDropsAgentRequestWhenOnlyTailsDiffer() throws {
        // Codex review finding: the helper's cache key is the NON-FINAL
        // messages only, so agent templates that differ from standard only
        // past the first placeholder prime the same checkpoint — a second
        // request would be wasted helper work.
        struct TailOnlyDiff: AppConfigServing {
            func configDirectoryURL() -> URL { URL(fileURLWithPath: "/dev/null") }
            func loadReplacementDictionary() -> ReplacementDictionary {
                ReplacementDictionary(entries: [])
            }
            func loadLLMPromptTemplates() -> LLMPromptTemplates {
                LLMPromptTemplates(systemContent: "system", userContent: "prefix {{input_text}}")
            }
            func loadLLMPromptTemplates(profile: PolishPromptProfile) -> LLMPromptTemplates {
                switch profile {
                case .standard:
                    return loadLLMPromptTemplates()
                case .agent:
                    return LLMPromptTemplates(
                        systemContent: "system",
                        userContent: "prefix {{input_text}} agent-only tail"
                    )
                }
            }
            func loadTerminalAppBundleIDs() -> [String] { [] }
        }

        let store = makeStore()
        store.llmPolishingEnabled = true
        store.agentPolishProfileEnabled = true

        let plan = try XCTUnwrap(
            PolishPromptWarmup.plan(settings: store, appConfigStore: TailOnlyDiff())
        )

        XCTAssertEqual(plan.requests.map(\.profile), [.standard])
    }

    func testPlanIsNilWhenPolishingDisabled() {
        let store = makeStore()
        store.llmPolishingEnabled = false

        XCTAssertNil(PolishPromptWarmup.plan(settings: store, appConfigStore: configStore))
    }

    func testPlanIsNilInExternalURLMode() {
        // Never warm someone else's server: an external chat/completions
        // endpoint gets no throwaway traffic even though polishing is
        // enabled and its configuration is valid.
        let store = makeStore()
        store.llmPolishingEnabled = true
        store.polishingBackendMode = .externalURL
        store.llmPolishingEndpointURL = "https://api.example.com/v1/chat/completions"
        store.llmPolishingAPIKey = "sk-test"

        XCTAssertNotNil(store.llmPolishingConfiguration, "precondition: external config is valid")
        XCTAssertNil(PolishPromptWarmup.plan(settings: store, appConfigStore: configStore))
    }
}
