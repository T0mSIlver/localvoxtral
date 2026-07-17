import Darwin
import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

@MainActor
final class BackendManagerTests: XCTestCase {
    func testBundledDictationBackendRecordsStartSequence() async throws {
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [
            .launching,
            .waitingForReady,
            .running,
        ]
        let manager = makeManager(supervisorFactory: supervisorFactory)
        var speechdStatuses: [ManagedBackendStatus] = []
        manager.debugStatusChangeSink = { spec, status in
            guard spec.id == BackendCatalog.speechd.id else { return }
            speechdStatuses.append(status)
        }

        try await manager.ensureReady(dictation: true, polishing: false)

        XCTAssertEqual(manager.speechdStatus, .ready)
        XCTAssertTrue(speechdStatuses.contains {
            if case .preparingModel = $0 { return true }
            return false
        })
        XCTAssertTrue(speechdStatuses.contains(.starting))
        XCTAssertEqual(speechdStatuses.last, .ready)
    }

    func testSpeechdConfigurationUsesBundlePathPinnedModelRevisionAndHFFileSet() async throws {
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        let manager = makeManager(
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: true, polishing: false)

        XCTAssertEqual(modelPreparer.prepareCalls.map(\.backendID), [BackendCatalog.speechd.id])
        XCTAssertEqual(supervisorFactory.createdConfigurations.map(\.name), [BackendCatalog.speechd.displayName])
        XCTAssertEqual(manager.speechdStatus, .ready)

        let option = SpeechModelCatalog.defaultOption
        XCTAssertEqual(modelPreparer.prepareCalls.count, 1)
        let request = try XCTUnwrap(modelPreparer.prepareCalls.first)
        XCTAssertEqual(request.repoID, option.repoID)
        XCTAssertEqual(request.revision, option.revision)
        XCTAssertEqual(
            request.includePatterns,
            [
                "config.json",
                "tekken.json",
                "tokenizer*.json",
                "model*.safetensors",
                "model.safetensors.index.json",
            ]
        )

        XCTAssertEqual(supervisorFactory.createdConfigurations.count, 1)
        let configuration = try XCTUnwrap(supervisorFactory.createdConfigurations.first)
        XCTAssertEqual(configuration.executableURL.lastPathComponent, "localvoxtral-speechd")
        XCTAssertFalse(configuration.executableURL.path.contains("backends"))
        XCTAssertEqual(configuration.readinessURL.absoluteString, "http://127.0.0.1:8471/health")
        XCTAssertTrue(configuration.arguments.contains("--parent-pid"))
        let modelIndex = try XCTUnwrap(configuration.arguments.firstIndex(of: "--model"))
        XCTAssertEqual(configuration.arguments[modelIndex + 1], option.repoID)
        let revisionIndex = try XCTUnwrap(
            configuration.arguments.firstIndex(of: "--model-revision")
        )
        XCTAssertEqual(configuration.arguments[revisionIndex + 1], option.revision)
        // Default providers are Auto: the cache-limit and step-cadence flags
        // are omitted so the helper's built-in defaults apply.
        XCTAssertFalse(configuration.arguments.contains("--cache-limit-mb"))
        XCTAssertFalse(configuration.arguments.contains("--step-ms"))
    }

    func testSpeechdCacheLimitAutoOmitsFlagAndPresetsAppendMegabytes() async throws {
        let option = SpeechModelCatalog.defaultOption
        let baseArguments = [
            "--model", option.repoID,
            "--model-revision", option.revision,
            "--port", "8471",
            "--parent-pid", "\(Darwin.getpid())",
        ]

        // Auto: identical to the base argument list, no cache-limit flag.
        let autoConfiguration = try await speechdConfiguration(cacheLimitMB: nil)
        XCTAssertEqual(autoConfiguration.arguments, baseArguments)

        // Each preset appends exactly `--cache-limit-mb <value>` and leaves the
        // model / revision / port / parent-pid arguments untouched.
        for megabytes in [2048, 4096, 6144, 8192] {
            let configuration = try await speechdConfiguration(cacheLimitMB: megabytes)
            XCTAssertEqual(
                configuration.arguments,
                baseArguments + ["--cache-limit-mb", "\(megabytes)"]
            )
        }
    }

    func testSpeechdStepCadenceAutoOmitsFlagAndPresetsAppendMilliseconds() async throws {
        let option = SpeechModelCatalog.defaultOption
        let baseArguments = [
            "--model", option.repoID,
            "--model-revision", option.revision,
            "--port", "8471",
            "--parent-pid", "\(Darwin.getpid())",
        ]

        // Auto: identical to the base argument list, no step-cadence flag.
        let autoConfiguration = try await speechdConfiguration(stepCadenceMs: nil)
        XCTAssertEqual(autoConfiguration.arguments, baseArguments)

        // Each preset appends exactly `--step-ms <value>` and leaves the
        // model / revision / port / parent-pid arguments untouched.
        for milliseconds in [100, 240, 480] {
            let configuration = try await speechdConfiguration(stepCadenceMs: milliseconds)
            XCTAssertEqual(
                configuration.arguments,
                baseArguments + ["--step-ms", "\(milliseconds)"]
            )
        }
    }

    /// Regression: launch arguments are captured at supervisor creation, so a
    /// stop must DROP the supervisor — a kept one would relaunch with stale
    /// settings (field-hit 2026-07-17: changing the memory limit and toggling
    /// Managed → External → Managed silently kept the old argv).
    func testStopDictationDropsSupervisorSoNextEnsureRebuildsArguments() async throws {
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        let stepCadenceMs = ProvidedValueBox()
        let manager = makeManager(
            speechdStepCadenceProvider: { stepCadenceMs.value },
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: true, polishing: false)
        await manager.stopDictation()
        stepCadenceMs.value = 100
        try await manager.ensureReady(dictation: true, polishing: false)

        let configurations = supervisorFactory.createdConfigurations
            .filter { $0.name == BackendCatalog.speechd.displayName }
        XCTAssertEqual(
            configurations.count, 2,
            "stopDictation must drop the supervisor so the next ensure rebuilds it"
        )
        XCTAssertFalse(try XCTUnwrap(configurations.first).arguments.contains("--step-ms"))
        XCTAssertEqual(
            Array(try XCTUnwrap(configurations.last).arguments.suffix(2)),
            ["--step-ms", "100"]
        )
    }

    /// Same contract for the full-stop path used when the app switches the
    /// dictation backend mode away from Managed.
    func testStopAllDropsSupervisorsSoNextEnsureRebuildsArguments() async throws {
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        let cacheLimitMB = ProvidedValueBox()
        let manager = makeManager(
            speechdCacheLimitProvider: { cacheLimitMB.value },
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: true, polishing: false)
        await manager.stopAll()
        cacheLimitMB.value = 2048
        try await manager.ensureReady(dictation: true, polishing: false)

        let configurations = supervisorFactory.createdConfigurations
            .filter { $0.name == BackendCatalog.speechd.displayName }
        XCTAssertEqual(
            configurations.count, 2,
            "stopAll must drop the supervisors so the next ensure rebuilds them"
        )
        XCTAssertEqual(
            Array(try XCTUnwrap(configurations.last).arguments.suffix(2)),
            ["--cache-limit-mb", "2048"]
        )
    }

    /// Starts speechd with the given cache-limit / step-cadence providers and
    /// returns the supervisor configuration it was launched with.
    private func speechdConfiguration(
        cacheLimitMB: Int? = nil,
        stepCadenceMs: Int? = nil
    ) async throws -> BackendProcessConfiguration {
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        let manager = makeManager(
            speechdCacheLimitProvider: { cacheLimitMB },
            speechdStepCadenceProvider: { stepCadenceMs },
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: true, polishing: false)

        return try XCTUnwrap(
            supervisorFactory.createdConfigurations
                .first { $0.name == BackendCatalog.speechd.displayName }
        )
    }

    func testPolishingFlagControlsWhetherPolishdIsTouched() async throws {
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: true, polishing: false)
        XCTAssertEqual(supervisorFactory.createdConfigurations.map(\.name), [BackendCatalog.speechd.displayName])
        XCTAssertEqual(modelPreparer.prepareCalls.map(\.backendID), [BackendCatalog.speechd.id])

        try await manager.ensureReady(dictation: true, polishing: true)
        // Set + count, not positional (concurrent ensure tasks): exactly one
        // creation/prepare per backend, speechd not re-done by the second call.
        XCTAssertEqual(
            Set(supervisorFactory.createdConfigurations.map(\.name)),
            [BackendCatalog.speechd.displayName, BackendCatalog.polishd.displayName]
        )
        XCTAssertEqual(supervisorFactory.createdConfigurations.count, 2)
        XCTAssertEqual(
            Set(modelPreparer.prepareCalls.map(\.backendID)),
            [BackendCatalog.speechd.id, BackendCatalog.polishd.id]
        )
        XCTAssertEqual(modelPreparer.prepareCalls.count, 2)
        XCTAssertEqual(manager.polishdStatus, .ready)

        let polishdConfiguration = try XCTUnwrap(
            supervisorFactory.createdConfigurations
                .first { $0.name == BackendCatalog.polishd.displayName }
        )
        // The bundled helper owns prompt handling internally; the supervisor
        // contract is model id + port + parent-pid tethering.
        XCTAssertTrue(polishdConfiguration.arguments.contains("--parent-pid"))
        XCTAssertEqual(
            polishdConfiguration.arguments.prefix(2),
            ["--model", SettingsStore.defaultLLMPolishingModel]
        )
        XCTAssertFalse(polishdConfiguration.arguments.contains("--prompt-cache-size"))
        // The bundled executable resolves next to the app binary, never from
        // the uv tools tree.
        XCTAssertEqual(
            polishdConfiguration.executableURL.lastPathComponent,
            BackendCatalog.polishd.executableName
        )
        XCTAssertFalse(polishdConfiguration.executableURL.path.contains("backends"))
    }

    /// Regression, 2026-07-14: the catalog pinned only a repo id, so the
    /// download and the helper's load both resolved the repo's main ref.
    /// Upstream added the vision tower to model.safetensors.index.json and
    /// every polish start died on a weight file we never fetch. Download and
    /// load must name the SAME pinned commit.
    func testPolishdDownloadsAndLoadsThePinnedModelRevision() async throws {
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: false, polishing: true)

        let pin = PolishModelCatalog.defaultOption.revision
        let request = try XCTUnwrap(
            modelPreparer.prepareCalls.first { $0.backendID == BackendCatalog.polishd.id }
        )
        XCTAssertEqual(request.repoID, SettingsStore.defaultLLMPolishingModel)
        XCTAssertEqual(request.revision, pin)

        let configuration = try XCTUnwrap(
            supervisorFactory.createdConfigurations
                .first { $0.name == BackendCatalog.polishd.displayName }
        )
        let arguments = configuration.arguments
        let flagIndex = try XCTUnwrap(arguments.firstIndex(of: "--model-revision"))
        XCTAssertEqual(arguments[arguments.index(after: flagIndex)], pin)
    }

    func testPolishingOnlyEnsureReadyDoesNotTouchSpeechd() async throws {
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: false, polishing: true)

        XCTAssertEqual(supervisorFactory.createdConfigurations.map(\.name), [BackendCatalog.polishd.displayName])
        XCTAssertEqual(modelPreparer.prepareCalls.map(\.backendID), [BackendCatalog.polishd.id])
        XCTAssertEqual(manager.speechdStatus, .stopped)
        XCTAssertEqual(manager.polishdStatus, .ready)
    }

    func testConcurrentEnsureReadyDoesNotDoublePrepareOrStartSpeechd() async throws {
        let modelPreparer = FakeModelPreparer(suspendBackendIDs: [BackendCatalog.speechd.id])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        let manager = makeManager(
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        let first = Task { @MainActor in
            try await manager.ensureReady(dictation: true, polishing: false)
        }
        await modelPreparer.waitUntilPrepareStarted()

        let second = Task { @MainActor in
            try await manager.ensureReady(dictation: true, polishing: false)
        }
        await Task.yield()

        XCTAssertEqual(modelPreparer.prepareCalls.map(\.backendID), [BackendCatalog.speechd.id])
        XCTAssertTrue(supervisorFactory.createdConfigurations.isEmpty)

        modelPreparer.resumePrepare()
        try await first.value
        try await second.value
        XCTAssertEqual(
            supervisorFactory.supervisors[BackendCatalog.speechd.displayName]?.startCallCount,
            1
        )
    }

    func testStopAllStopsBothSupervisors() async throws {
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: true, polishing: true)
        await manager.stopAll()

        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.speechd.displayName]?.stopCallCount, 1)
        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.polishd.displayName]?.stopCallCount, 1)
        XCTAssertEqual(manager.speechdStatus, .stopped)
        XCTAssertEqual(manager.polishdStatus, .stopped)
    }

    func testStopPolishingStopsOnlyPolishd() async throws {
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: true, polishing: true)
        XCTAssertEqual(manager.speechdStatus, .ready)
        XCTAssertEqual(manager.polishdStatus, .ready)

        await manager.stopPolishing()

        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.polishd.displayName]?.stopCallCount, 1)
        XCTAssertEqual(manager.polishdStatus, .stopped)
        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.speechd.displayName]?.stopCallCount, 0)
        XCTAssertEqual(manager.speechdStatus, .ready)
    }

    func testModelChangeStopsSupervisorAndNextEnsureUsesNewModel() async throws {
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let settings = SettingsStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let manager = makeManager(
            modelPreparer: modelPreparer,
            polishingModelProvider: { settings.managedLLMPolishingModel },
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: false, polishing: true)
        let firstSupervisor = try XCTUnwrap(
            supervisorFactory.supervisors[BackendCatalog.polishd.displayName]
        )

        settings.managedLLMPolishingModel = "example/new-polishing-model"
        await manager.stopPolishing()
        XCTAssertEqual(firstSupervisor.stopCallCount, 1)

        try await manager.ensureReady(dictation: false, polishing: true)

        XCTAssertEqual(
            modelPreparer.prepareCalls.map(\.repoID),
            [SettingsStore.defaultLLMPolishingModel, "example/new-polishing-model"]
        )
        let relaunchedConfiguration = try XCTUnwrap(
            supervisorFactory.createdConfigurations.last
        )
        XCTAssertEqual(
            Array(relaunchedConfiguration.arguments.prefix(2)),
            ["--model", "example/new-polishing-model"]
        )
        // A custom repo id has no catalog pin: it tracks main, in the download
        // and in the helper's load alike. Pinning a revision we never chose
        // would point the helper at a snapshot that cannot exist.
        XCTAssertFalse(relaunchedConfiguration.arguments.contains("--model-revision"))
        XCTAssertNil(modelPreparer.prepareCalls.last?.revision)
    }

    func testStopPolishingAwaitsCancelledEnsureSoASubsequentEnsureStartsFresh() async throws {
        // Field regression (PR #99): stop cancelled the in-flight ensure but
        // returned without awaiting it, so a model switch mid-download started
        // a second downloader process while the first was still terminating —
        // both writing the same HF cache blob. Stop must not return until the
        // cancelled ensure (and its downloader) fully unwound.
        let modelPreparer = FakeModelPreparer(suspendBackendIDs: [BackendCatalog.polishd.id])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        let firstEnsure = Task { @MainActor in
            try await manager.ensureReady(dictation: false, polishing: true)
        }
        await modelPreparer.waitUntilPrepareStarted()

        await manager.stopPolishing()

        // The cancelled prepare observed its termination BEFORE stop returned…
        XCTAssertEqual(modelPreparer.terminatedBackendIDs, [BackendCatalog.polishd.id])
        // …so a new ensure starts fresh instead of joining the dead
        // single-flight task (which would rethrow its CancellationError).
        try await manager.ensureReady(dictation: false, polishing: true)
        XCTAssertEqual(modelPreparer.prepareCalls.count, 2)
        XCTAssertEqual(manager.polishdStatus, .ready)
        _ = await firstEnsure.result
    }

    func testStopDictationStopsOnlySpeechd() async throws {
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: true, polishing: true)
        XCTAssertEqual(manager.speechdStatus, .ready)
        XCTAssertEqual(manager.polishdStatus, .ready)

        await manager.stopDictation()

        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.speechd.displayName]?.stopCallCount, 1)
        XCTAssertEqual(manager.speechdStatus, .stopped)
        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.polishd.displayName]?.stopCallCount, 0)
        XCTAssertEqual(manager.polishdStatus, .ready)
    }

    func testSupervisorStateMirrorMarksLaterFailureAndNextEnsureDoesNotShortCircuit() async throws {
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        let manager = makeManager(supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: true, polishing: false)
        let supervisor = try XCTUnwrap(supervisorFactory.supervisors[BackendCatalog.speechd.displayName])
        XCTAssertEqual(manager.speechdStatus, .ready)
        XCTAssertEqual(supervisor.startCallCount, 1)

        // Deterministic happens-before edge for the mirror's async consumption
        // task: subscribe BEFORE emitting, then drain the stream until the
        // failure lands. The previous single `Task.yield()` is not a
        // synchronization point — under scheduler load the mirror was still
        // `.ready` when asserted (pre-existing flake on main, surfaced by CI
        // load on 2026-07-11). Assertions unchanged.
        let statusUpdates = manager.statusUpdates
        supervisor.emit(.failed(summary: "process crashed after readiness", detail: nil))
        for await update in statusUpdates {
            if update.spec.id == BackendCatalog.speechd.id, case .failed = update.status {
                break
            }
        }

        XCTAssertEqual(manager.speechdStatus, .failed(summary: "process crashed after readiness", detail: nil))

        try await manager.ensureReady(dictation: true, polishing: false)

        XCTAssertEqual(supervisor.startCallCount, 2)
        XCTAssertEqual(manager.speechdStatus, .ready)
    }

    func testBundledBackendConfigurationsUseModelLoadReadinessTimeouts() async throws {
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: true, polishing: true)

        // Keyed by backend, not positional: the two ensure tasks run
        // concurrently, so their creation order is not a contract.
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: supervisorFactory.createdConfigurations
                    .map { ($0.name, $0.readinessTimeout) }
            ),
            [
                BackendCatalog.speechd.displayName: .seconds(300),
                BackendCatalog.polishd.displayName: .seconds(300),
            ]
        )
    }

    func testEnsureReadySurfacesModelPreparationBeforeStarting() async throws {
        let modelPreparer = FakeModelPreparer(
            scriptedProgress: [
                BackendCatalog.speechd.id: [
                    ModelDownloadProgress(downloadedBytes: 0, totalBytes: 100),
                    ModelDownloadProgress(downloadedBytes: 40, totalBytes: 100),
                ],
            ]
        )
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        let manager = makeManager(
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )
        var speechdStatuses: [ManagedBackendStatus] = []
        manager.debugStatusChangeSink = { spec, status in
            guard spec.id == BackendCatalog.speechd.id else { return }
            speechdStatuses.append(status)
        }

        try await manager.ensureReady(dictation: true, polishing: false)

        XCTAssertEqual(
            modelPreparer.prepareCalls.map(\.repoID),
            [SpeechModelCatalog.defaultOption.repoID]
        )
        XCTAssertTrue(speechdStatuses.contains(.preparingModel(progress: ModelDownloadProgress(downloadedBytes: 40, totalBytes: 100))))
        XCTAssertTrue(speechdStatuses.contains(.starting))
        XCTAssertEqual(speechdStatuses.last, .ready)
        XCTAssertLessThan(
            try XCTUnwrap(speechdStatuses.firstIndex(of: .preparingModel(progress: ModelDownloadProgress(downloadedBytes: 40, totalBytes: 100)))),
            try XCTUnwrap(speechdStatuses.firstIndex(of: .starting))
        )
    }

    func testEnsureReadyWithPolishingPreparesBothModels() async throws {
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: true, polishing: true)

        // Keyed by backend, not positional (concurrent ensure tasks), which
        // also pins each backend to ITS model rather than just the order.
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: modelPreparer.prepareCalls
                    .map { ($0.backendID, $0.repoID) }
            ),
            [
                BackendCatalog.speechd.id: SpeechModelCatalog.defaultOption.repoID,
                BackendCatalog.polishd.id: SettingsStore.defaultLLMPolishingModel,
            ]
        )
    }

    func testEnsureReadyWithoutPolishingPreparesOnlySpeechd() async throws {
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: true, polishing: false)

        XCTAssertEqual(modelPreparer.prepareCalls.map(\.backendID), [BackendCatalog.speechd.id])
        XCTAssertEqual(supervisorFactory.createdConfigurations.map(\.name), [BackendCatalog.speechd.displayName])
    }

    func testCancellingEnsureReadyDuringModelPreparationTerminatesAndDoesNotMarkReady() async throws {
        let modelPreparer = FakeModelPreparer(suspendBackendIDs: [BackendCatalog.speechd.id])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        let manager = makeManager(
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        let task = Task { @MainActor in
            try await manager.ensureReady(dictation: true, polishing: false)
        }
        await modelPreparer.waitUntilPrepareStarted()

        task.cancel()

        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertEqual(modelPreparer.terminatedBackendIDs, [BackendCatalog.speechd.id])
        XCTAssertTrue(supervisorFactory.createdConfigurations.isEmpty)
        XCTAssertEqual(manager.speechdStatus, .stopped)
    }

    func testStopPolishingCancelsInFlightEnsureBeforeSupervisorCanStart() async throws {
        let modelPreparer = FakeModelPreparer(suspendBackendIDs: [BackendCatalog.polishd.id])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        let task = Task { @MainActor in
            try await manager.ensureReady(dictation: false, polishing: true)
        }
        await modelPreparer.waitUntilPrepareStarted()

        await manager.stopPolishing()

        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertEqual(modelPreparer.terminatedBackendIDs, [BackendCatalog.polishd.id])
        XCTAssertTrue(supervisorFactory.createdConfigurations.isEmpty)
        XCTAssertEqual(manager.polishdStatus, .stopped)
    }

    func testModelPreparationFailureMarksBackendFailedWithDetails() async {
        let marker = "HF_TRACE"
        let modelPreparer = FakeModelPreparer(
            failures: [
                BackendCatalog.speechd.id: ModelDownloadError.transport(
                    message: "Hugging Face rejected the request.",
                    detail: "stderr \(marker)"
                ),
            ]
        )
        let manager = makeManager(
            modelPreparer: modelPreparer,
            supervisorFactory: FakeSupervisorFactory()
        )

        do {
            try await manager.ensureReady(dictation: true, polishing: false)
            XCTFail("expected ensureReady to throw")
        } catch let error as ManagedBackendManagerError {
            XCTAssertEqual(
                error.localizedDescription,
                "Dictation engine failed: Hugging Face rejected the request."
            )
            XCTAssertEqual(error.technicalDetails, "stderr \(marker)")
        } catch {
            XCTFail("expected ManagedBackendManagerError, got \(error)")
        }

        XCTAssertEqual(
            manager.speechdStatus,
            .failed(summary: "Hugging Face rejected the request.", detail: "stderr \(marker)")
        )
    }

    func testSupervisorFailureErrorSplitsSummaryFromTechnicalDetails() async throws {
        let marker = "FAKE_STDERR_TRACEBACK"
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [
            .failed(
                summary: "polishd exited 5 consecutive times.",
                detail: "stderr: traceback \(marker)"
            ),
        ]
        let manager = makeManager(supervisorFactory: supervisorFactory)

        do {
            try await manager.ensureReady(dictation: true, polishing: true)
            XCTFail("expected ensureReady to throw")
        } catch let error as ManagedBackendManagerError {
            XCTAssertEqual(
                error.localizedDescription,
                "Polishing engine failed: polishd exited 5 consecutive times."
            )
            XCTAssertFalse(error.localizedDescription.contains(marker))
            XCTAssertTrue(error.technicalDetails?.contains(marker) == true)
        } catch {
            XCTFail("expected ManagedBackendManagerError, got \(error)")
        }

        XCTAssertEqual(
            manager.polishdStatus,
            .failed(
                summary: "polishd exited 5 consecutive times.",
                detail: "stderr: traceback \(marker)"
            )
        )
    }

    func testPolishingEnsureIsNotBlockedByAStuckDictationEnsure() async throws {
        let supervisorFactory = FakeSupervisorFactory()
        // speechd never reaches .running: its ensure blocks awaiting readiness.
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = []
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(supervisorFactory: supervisorFactory)

        let stuckDictation = Task { try await manager.ensureReady(dictation: true, polishing: false) }
        while supervisorFactory.supervisors[BackendCatalog.speechd.displayName]?.startCallCount != 1 {
            await Task.yield()
        }

        // Field regression (2026-07-04): with one shared single-flight slot,
        // this joined the stuck dictation run — whose flags never covered
        // polishing — and silently never started polishd.
        try await manager.ensureReady(dictation: false, polishing: true)
        XCTAssertEqual(manager.polishdStatus, .ready)
        XCTAssertEqual(
            supervisorFactory.supervisors[BackendCatalog.polishd.displayName]?.startCallCount, 1
        )

        stuckDictation.cancel()
        _ = try? await stuckDictation.value
    }

    func testSecondEnsureReadyAddsPolishingAfterDictationOnlyRun() async throws {
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.speechd.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(supervisorFactory: supervisorFactory)

        // First dictation: polishing disabled at the time.
        try await manager.ensureReady(dictation: true, polishing: false)
        XCTAssertEqual(manager.speechdStatus, .ready)
        XCTAssertEqual(manager.polishdStatus, .stopped)

        // User enables polishing, dictates again: polishd must come up now.
        try await manager.ensureReady(dictation: true, polishing: true)
        XCTAssertEqual(manager.polishdStatus, .ready)
        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.polishd.displayName]?.startCallCount, 1)
    }

    func testUnownedSpeechdPortOccupantSurfacesNormalConflictWithoutStarting() async {
        let supervisorFactory = FakeSupervisorFactory()
        let occupant = ListeningProcess(
            pid: 999,
            executableURL: URL(fileURLWithPath: "/Applications/Other.app/Contents/MacOS/server")
        )
        let manager = makeManager(
            legacyPortDefense: FixedLegacyPortDefense(outcome: .occupiedByOther(occupant)),
            supervisorFactory: supervisorFactory
        )

        do {
            try await manager.ensureReady(dictation: true, polishing: false)
            XCTFail("expected port conflict")
        } catch let error as ManagedBackendManagerError {
            XCTAssertTrue(error.localizedDescription.contains("port already in use"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(supervisorFactory.createdConfigurations.isEmpty)
    }

    private func makeManager(
        modelPreparer: FakeModelPreparer = FakeModelPreparer(),
        legacyPortDefense: any LegacyVoxmlxPortDefending = FixedLegacyPortDefense(outcome: .available),
        polishingModelProvider: @escaping BackendManager.PolishingModelProvider = {
            SettingsStore.defaultLLMPolishingModel
        },
        speechdCacheLimitProvider: @escaping BackendManager.SpeechdCacheLimitProvider = { nil },
        speechdStepCadenceProvider: @escaping BackendManager.SpeechdStepCadenceProvider = { nil },
        supervisorFactory: FakeSupervisorFactory
    ) -> BackendManager {
        BackendManager(
            modelPreparer: modelPreparer,
            layout: BackendInstallLayout(root: URL(fileURLWithPath: "/tmp/localvoxtral-backend-manager-tests")),
            legacyPortDefense: legacyPortDefense,
            polishingModelProvider: polishingModelProvider,
            speechdCacheLimitProvider: speechdCacheLimitProvider,
            speechdStepCadenceProvider: speechdStepCadenceProvider,
            supervisorFactory: { configuration in
                supervisorFactory.makeSupervisor(configuration: configuration)
            }
        )
    }
}

/// Mutable value for settings-provider closures in tests. The providers are
/// `@MainActor` and the tests mutate on the main actor too, but a captured
/// `var` still trips the sendable-capture warning — box it instead.
private final class ProvidedValueBox: @unchecked Sendable {
    var value: Int?
}

private struct FixedLegacyPortDefense: LegacyVoxmlxPortDefending {
    let outcome: LegacyVoxmlxPortOutcome

    func clearLegacyOccupantIfNeeded(port: Int) async -> LegacyVoxmlxPortOutcome {
        outcome
    }
}

// `prepare` is nonisolated async, so ensureReady's concurrent per-backend
// tasks call it off the main actor simultaneously — the recorded state must
// be lock-protected or appends race and can be lost (flaked on the runner
// under dogfooding load, PR #94).
private final class FakeModelPreparer: ModelPreparing, @unchecked Sendable {
    private struct State {
        var prepareCalls: [ModelPreparationRequest] = []
        var terminatedBackendIDs: [String] = []
        var alreadySuspendedBackendIDs: Set<String> = []
        var prepareStartedContinuation: CheckedContinuation<Void, Never>?
        var prepareResumeContinuation: CheckedContinuation<Void, Error>?
    }

    private let scriptedProgress: [String: [ModelDownloadProgress]]
    private let failures: [String: Error]
    private let suspendBackendIDs: Set<String>
    private let state = Mutex(State())

    var prepareCalls: [ModelPreparationRequest] { state.withLock { $0.prepareCalls } }
    var terminatedBackendIDs: [String] { state.withLock { $0.terminatedBackendIDs } }

    init(
        scriptedProgress: [String: [ModelDownloadProgress]] = [:],
        failures: [String: Error] = [:],
        suspendBackendIDs: Set<String> = []
    ) {
        self.scriptedProgress = scriptedProgress
        self.failures = failures
        self.suspendBackendIDs = suspendBackendIDs
    }

    func prepare(
        _ request: ModelPreparationRequest,
        progress: @MainActor @Sendable @escaping (ModelDownloadProgress) -> Void
    ) async throws {
        let started: CheckedContinuation<Void, Never>? = state.withLock {
            $0.prepareCalls.append(request)
            let continuation = $0.prepareStartedContinuation
            $0.prepareStartedContinuation = nil
            return continuation
        }
        started?.resume()

        for event in scriptedProgress[request.backendID] ?? [] {
            await progress(event)
        }

        // Suspend only the FIRST prepare per backend: retry-after-stop tests
        // need the follow-up prepare to complete normally.
        let shouldSuspend = suspendBackendIDs.contains(request.backendID)
            && state.withLock { $0.alreadySuspendedBackendIDs.insert(request.backendID).inserted }
        if shouldSuspend {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    state.withLock { $0.prepareResumeContinuation = continuation }
                }
            } onCancel: {
                let continuation: CheckedContinuation<Void, Error>? = self.state.withLock {
                    $0.terminatedBackendIDs.append(request.backendID)
                    let continuation = $0.prepareResumeContinuation
                    $0.prepareResumeContinuation = nil
                    return continuation
                }
                continuation?.resume(throwing: CancellationError())
            }
        }

        if let failure = failures[request.backendID] {
            throw failure
        }
    }

    func waitUntilPrepareStarted() async {
        await withCheckedContinuation { continuation in
            let alreadyStarted: Bool = state.withLock {
                if $0.prepareCalls.isEmpty {
                    $0.prepareStartedContinuation = continuation
                    return false
                }
                return true
            }
            if alreadyStarted {
                continuation.resume()
            }
        }
    }

    func resumePrepare() {
        let continuation: CheckedContinuation<Void, Error>? = state.withLock {
            let continuation = $0.prepareResumeContinuation
            $0.prepareResumeContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

@MainActor
private final class FakeSupervisorFactory {
    var statesByName: [String: [BackendProcessSupervisor.State]] = [:]
    private(set) var createdConfigurations: [BackendProcessConfiguration] = []
    private(set) var supervisors: [String: FakeBackendSupervisor] = [:]

    func makeSupervisor(configuration: BackendProcessConfiguration) -> FakeBackendSupervisor {
        createdConfigurations.append(configuration)
        let supervisor = FakeBackendSupervisor(
            statesOnStart: statesByName[configuration.name] ?? [.running]
        )
        supervisors[configuration.name] = supervisor
        return supervisor
    }
}

@MainActor
private final class FakeBackendSupervisor: ManagedBackendSupervising {
    private let statesOnStart: [BackendProcessSupervisor.State]
    private var stateContinuations: [UUID: AsyncStream<BackendProcessSupervisor.State>.Continuation] = [:]

    private(set) var state: BackendProcessSupervisor.State = .idle
    var recentOutput: [String] = []
    var stateUpdates: AsyncStream<BackendProcessSupervisor.State> {
        let id = UUID()
        let stream = AsyncStream<BackendProcessSupervisor.State>.makeStream(of: BackendProcessSupervisor.State.self)
        stateContinuations[id] = stream.continuation
        stream.continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stateContinuations[id] = nil
            }
        }
        return stream.stream
    }
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    init(statesOnStart: [BackendProcessSupervisor.State]) {
        self.statesOnStart = statesOnStart
    }

    func start() async {
        startCallCount += 1
        for state in statesOnStart {
            emit(state)
        }
    }

    func stop() async {
        stopCallCount += 1
        emit(.stopped)
    }

    func emit(_ state: BackendProcessSupervisor.State) {
        self.state = state
        for continuation in stateContinuations.values {
            continuation.yield(state)
        }
    }
}
