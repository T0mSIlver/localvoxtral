import Foundation
import XCTest

@testable import localvoxtral

@MainActor
final class PolishPromptWarmupTests: XCTestCase {
    // MARK: - Fakes

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

    // MARK: - Helpers

    private func makePlan() -> (
        request: LLMPolishingRequest, configuration: LLMPolishingConfiguration
    ) {
        (
            request: LLMPolishingRequest(
                inputText: "warm",
                systemPrompt: "system",
                userPrompts: ["static prefix", "tail"],
                maxTokens: 1
            ),
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

    func testWarmupIgnoresVoxmlxUpdates() async {
        let service = RecordingPolishService()
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan()] in plan }
        )

        coordinator.handleStatusUpdate(update(BackendCatalog.voxmlx, .ready))
        await awaitWarmup(coordinator)
        XCTAssertTrue(service.requests.isEmpty)

        // A voxmlx non-ready update must not reset polishd's edge state.
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        coordinator.handleStatusUpdate(update(BackendCatalog.voxmlx, .stopped))
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
        var planAvailable = false
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan()] in planAvailable ? plan : nil }
        )

        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertNil(coordinator.warmupTask)
        XCTAssertTrue(service.requests.isEmpty)

        planAvailable = true
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
        XCTAssertEqual(plan.request.maxTokens, 1)
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
