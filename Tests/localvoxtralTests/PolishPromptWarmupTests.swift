import Foundation
import Observation
import XCTest

@testable import localvoxtral

/// Stands in for `SettingsStore`: the plan reads it, so observation tracks it.
@Observable
@MainActor
final class WarmupPlanInputs {
    var systemPrompt = "system one"
}

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
                    // The test cancels as soon as `started` fires; on a loaded
                    // host that cancellation can precede this store, in which
                    // case the handler below already ran and found nothing.
                    // Never park a continuation in a cancelled task (hosted
                    // unit-suite hang, 2026-09-07).
                    lock.lock()
                    let orphaned = Task.isCancelled
                    if !orphaned { self.continuation = continuation }
                    lock.unlock()
                    if orphaned { continuation.resume(throwing: CancellationError()) }
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
                        // Same rule as above: a task already cancelled when
                        // it gets here has had its handler run; resume now
                        // instead of parking a continuation nobody holds.
                        lock.lock()
                        let orphaned = Task.isCancelled
                        if !orphaned { self.continuation = continuation }
                        lock.unlock()
                        if orphaned { continuation.resume() }
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

    /// First polish call waits until `release()`, then succeeds; later calls
    /// answer immediately. Event-driven, no wall clock.
    private final class GatedPolishService: LLMPolishingServicing, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private var recordedRequests: [LLMPolishingRequest] = []
        let started = XCTestExpectation(description: "first polish request reached the service")

        var requests: [LLMPolishingRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }

        func release() {
            lock.lock()
            released = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
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
                await withCheckedContinuation { continuation in
                    lock.lock()
                    let go = released
                    if !go { self.continuation = continuation }
                    lock.unlock()
                    if go { continuation.resume() }
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

    // MARK: - Re-warming after the cached start changes (#489)

    /// Non-observable, like a prompt TOML on disk.
    private final class DiskTemplate: @unchecked Sendable {
        var systemPrompt = "disk one"
    }

    private func plan(systemPrompt: String) -> (
        requests: [PolishPromptWarmup.ProfiledRequest],
        configuration: LLMPolishingConfiguration
    ) {
        let base = makePlan()
        return (
            requests: [PolishPromptWarmup.ProfiledRequest(
                profile: .standard,
                request: LLMPolishingRequest(
                    inputText: "warm",
                    systemPrompt: systemPrompt,
                    userPrompts: ["static prefix", "tail"],
                    maxTokens: 1
                )
            )],
            configuration: base.configuration
        )
    }

    /// Settles a settings-driven warmup: advances past the settle delay and
    /// waits for the warmup it starts.
    private func settle(
        _ coordinator: PolishPromptWarmupCoordinator,
        _ clock: ManualSessionClock
    ) async {
        await clock.waitForSleepers(1)
        let settling = coordinator.settleTask
        clock.advance(by: 1.5)
        await settling?.value
        await awaitWarmup(coordinator)
    }

    func testSettingsChangeRewarmsOnceAfterABurstOfEdits() async throws {
        let service = RecordingPolishService()
        let inputs = WarmupPlanInputs()
        let clock = ManualSessionClock()
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [unowned self] in self.plan(systemPrompt: inputs.systemPrompt) },
            clock: clock.clock
        )
        coordinator.observePlanInputs()
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.map(\.systemPrompt), ["system one"])

        // Typing in About you: every keystroke changes the prefix. Each
        // edit restarts the settle delay, so only the last one is warmed.
        inputs.systemPrompt = "system t"
        await clock.waitForSleepers(1)
        let firstSettle = try XCTUnwrap(coordinator.settleTask)
        inputs.systemPrompt = "system two"
        // The change reaches the coordinator through a main-actor hop; a
        // bounded wait that fails, rather than hangs, if it never arrives.
        for _ in 0..<1000 where coordinator.settleTask == firstSettle {
            await Task.yield()
        }
        XCTAssertNotEqual(coordinator.settleTask, firstSettle, "the second edit restarts the settle")
        XCTAssertTrue(firstSettle.isCancelled)
        await settle(coordinator, clock)

        XCTAssertEqual(
            service.requests.map(\.systemPrompt), ["system one", "system two"],
            "a burst of edits must warm the final prefix exactly once"
        )
    }

    func testSettingsChangeBeforeHelperIsReadyWarmsOnlyAtReady() async {
        let service = RecordingPolishService()
        let inputs = WarmupPlanInputs()
        let clock = ManualSessionClock()
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [unowned self] in self.plan(systemPrompt: inputs.systemPrompt) },
            clock: clock.clock
        )
        coordinator.observePlanInputs()

        inputs.systemPrompt = "system two"
        await settle(coordinator, clock)
        XCTAssertTrue(service.requests.isEmpty, "no helper, nothing to warm")

        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.map(\.systemPrompt), ["system two"])
    }

    /// A prompt TOML edited on disk is invisible to observation; the
    /// dictation start is where it gets caught, and only once.
    func testDictationStartWarmsAPrefixThatChangedOnDisk() async {
        let service = RecordingPolishService()
        let disk = DiskTemplate()
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [unowned self] in self.plan(systemPrompt: disk.systemPrompt) }
        )
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)

        coordinator.ensureWarm(reason: "dictation start")
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.count, 1, "an unchanged prefix is not warmed again")

        disk.systemPrompt = "disk two"
        coordinator.ensureWarm(reason: "dictation start")
        await awaitWarmup(coordinator)
        coordinator.ensureWarm(reason: "dictation start")
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.map(\.systemPrompt), ["disk one", "disk two"])

        // Changing back warms again: the helper's few LRU slots may no
        // longer hold the old prefix.
        disk.systemPrompt = "disk one"
        coordinator.ensureWarm(reason: "dictation start")
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.map(\.systemPrompt), ["disk one", "disk two", "disk one"])
    }

    func testFailedWarmupIsRetriedOnTheNextDictationStart() async {
        let service = RecordingPolishService()
        service.setFailure(LLMPolishingError.networkError("connection refused"))
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan()] in plan }
        )
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)

        service.setFailure(nil)
        coordinator.ensureWarm(reason: "dictation start")
        await awaitWarmup(coordinator)
        coordinator.ensureWarm(reason: "dictation start")
        await awaitWarmup(coordinator)
        XCTAssertEqual(service.requests.count, 2, "retried once, then warm")
    }

    /// Codex review finding: a warmup left running for a prefix the plan
    /// dropped (agent profile turned off mid-warmup) held the helper ahead of
    /// the next real polish. Reconciling to an empty set cancels it.
    func testWarmupForAPrefixNoLongerPlannedIsCancelled() async {
        let service = SuspendingPolishService()
        let planned = LockedBool(true)
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan(), empty = makePlan(profiles: [])] in
                planned.value ? plan : empty
            }
        )
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await fulfillment(of: [service.started], timeout: 5)

        // Asserted right after the call, not after awaiting the task: without
        // the fix the suspended warmup never ends, and awaiting it would hang
        // the suite instead of failing. `cancel()` runs the fake's handler
        // synchronously.
        planned.set(false)
        coordinator.ensureWarm(reason: "settings change")
        XCTAssertTrue(service.observedCancellation)
        XCTAssertNil(coordinator.warmupTask)
        coordinator.cancelTasks()
    }

    func testAPrefixThatKeepsFailingStopsBeingRetriedUntilTheNextLaunch() async {
        let service = RecordingPolishService()
        service.setFailure(LLMPolishingError.networkError("rejected"))
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan()] in plan }
        )
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        for _ in 0..<5 {
            coordinator.ensureWarm(reason: "dictation start")
            await awaitWarmup(coordinator)
        }
        XCTAssertEqual(service.requests.count, PolishPromptWarmupCoordinator.maxFailuresPerLaunch)

        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .stopped))
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        XCTAssertEqual(
            service.requests.count, PolishPromptWarmupCoordinator.maxFailuresPerLaunch + 1,
            "a new helper launch gets a fresh try"
        )
    }

    /// Opus review finding: turning the agent profile off while the standard
    /// warmup ran cancelled it and sent the standard prefix again. The running
    /// task now finishes the standard prefix and skips the dropped one.
    func testDroppingAProfileMidWarmupKeepsTheRunningRequestAndSkipsTheDroppedOne() async {
        let service = GatedPolishService()
        let bothProfiles = LockedBool(true)
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: {
                [both = makePlan(profiles: [.standard, .agent]), standard = makePlan()] in
                bothProfiles.value ? both : standard
            }
        )
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await fulfillment(of: [service.started], timeout: 5)
        let running = coordinator.warmupTask

        bothProfiles.set(false)
        coordinator.ensureWarm(reason: "settings change")
        XCTAssertEqual(coordinator.warmupTask, running, "the running warmup is kept")
        XCTAssertEqual(running?.isCancelled, false)

        service.release()
        await awaitWarmup(coordinator)
        XCTAssertEqual(
            service.requests.map(\.systemPrompt), ["system standard"],
            "the standard prefix is sent once and the dropped agent prefix never"
        )
        coordinator.ensureWarm(reason: "dictation start")
        XCTAssertNil(coordinator.warmupTask, "the standard prefix counts as warm")
    }

    func testDictationStartDoesNothingWhileHelperIsNotReady() async {
        let service = RecordingPolishService()
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { [plan = makePlan()] in plan }
        )
        coordinator.ensureWarm(reason: "dictation start")
        XCTAssertNil(coordinator.warmupTask)

        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .ready))
        await awaitWarmup(coordinator)
        coordinator.handleStatusUpdate(update(BackendCatalog.polishd, .stopped))
        coordinator.ensureWarm(reason: "dictation start")
        XCTAssertNil(coordinator.warmupTask, "a stopped helper is warmed at its next ready")
        XCTAssertEqual(service.requests.count, 1)
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
        SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
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

    /// The production wiring: the plan reads `SettingsStore`, so editing
    /// About you, accepting a term, or turning the agent profile on re-warms
    /// the changed prefixes once the edits settle, with no helper restart.
    func testEditingSettingsTheCachedStartReadsRewarmsIt() async throws {
        let store = makeStore()
        store.llmPolishingEnabled = true
        store.agentPolishProfileEnabled = false
        let service = FakePolishingService()
        let clock = ManualSessionClock()
        let configStore = profileAwareConfigStore
        let coordinator = PolishPromptWarmupCoordinator(
            serviceProvider: { service },
            planProvider: { PolishPromptWarmup.plan(settings: store, appConfigStore: configStore) },
            clock: clock.clock
        )
        coordinator.observePlanInputs()
        coordinator.handleStatusUpdate(
            ManagedBackendStatusUpdate(spec: BackendCatalog.polishd, status: .ready))
        await coordinator.warmupTask?.value
        var sent = await service.requests.count
        XCTAssertEqual(sent, 1)

        func settle() async {
            await clock.waitForSleepers(1)
            let settling = coordinator.settleTask
            clock.advance(by: 1.5)
            await settling?.value
            await coordinator.warmupTask?.value
        }

        store.polishSpeakerProfile = "I work on localvoxtral."
        await settle()
        sent = await service.requests.count
        XCTAssertEqual(sent, 2)
        let profileRequest = await service.lastRequest
        XCTAssertTrue(profileRequest?.systemPrompt.contains("I work on localvoxtral.") == true)

        store.polishSpeakerTerms = ["Voxtral"]
        await settle()
        let termsRequest = await service.lastRequest
        XCTAssertTrue(termsRequest?.systemPrompt.contains("Voxtral") == true)

        store.agentPolishProfileEnabled = true
        await settle()
        let systemPrompts = await service.requests.map(\.systemPrompt)
        XCTAssertEqual(systemPrompts.count, 4, "only the newly planned agent prefix is warmed")
        XCTAssertTrue(systemPrompts.last?.hasPrefix("agent system") == true)
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
