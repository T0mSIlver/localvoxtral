import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

@MainActor
final class BackendManagerTests: XCTestCase {
    func testInstallThenStartHappyPathRecordsStatusSequence() async throws {
        let installer = FakeBackendInstaller(needsInstall: [BackendCatalog.voxmlx.id])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [
            .launching,
            .waitingForReady,
            .running,
        ]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)
        var voxmlxStatuses: [ManagedBackendStatus] = []
        manager.debugStatusChangeSink = { spec, status in
            guard spec.id == BackendCatalog.voxmlx.id else { return }
            voxmlxStatuses.append(status)
        }

        try await manager.ensureReady(dictation: true, polishing: false)

        XCTAssertEqual(installer.installCalls.map(\.id), [BackendCatalog.voxmlx.id])
        XCTAssertEqual(manager.voxmlxStatus, .ready)
        XCTAssertTrue(voxmlxStatuses.contains(.installing(progress: .downloading(fraction: nil))))
        XCTAssertTrue(voxmlxStatuses.contains(.installing(progress: .verifying)))
        XCTAssertTrue(voxmlxStatuses.contains(.starting))
        XCTAssertEqual(voxmlxStatuses.last, .ready)
    }

    func testAlreadyInstalledSkipsInstaller() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        let manager = makeManager(
            installer: installer,
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: true, polishing: false)

        XCTAssertTrue(installer.installCalls.isEmpty)
        XCTAssertEqual(modelPreparer.prepareCalls.map(\.backendID), [BackendCatalog.voxmlx.id])
        XCTAssertEqual(supervisorFactory.createdConfigurations.map(\.name), [BackendCatalog.voxmlx.displayName])
        XCTAssertEqual(manager.voxmlxStatus, .ready)
    }

    func testInstallFailureMarksBackendFailed() async {
        let installer = FakeBackendInstaller(
            needsInstall: [BackendCatalog.voxmlx.id],
            installFailures: [BackendCatalog.voxmlx.id: FakeBackendError(message: "wheel unavailable")]
        )
        let manager = makeManager(installer: installer, supervisorFactory: FakeSupervisorFactory())

        do {
            try await manager.ensureReady(dictation: true, polishing: false)
            XCTFail("expected ensureReady to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("voxmlx"))
            XCTAssertTrue(error.localizedDescription.contains("wheel unavailable"))
        }

        XCTAssertEqual(manager.voxmlxStatus, .failed(summary: "wheel unavailable", detail: nil))
    }

    func testPolishingFlagControlsWhetherPolishdIsTouched() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(
            installer: installer,
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: true, polishing: false)
        XCTAssertEqual(supervisorFactory.createdConfigurations.map(\.name), [BackendCatalog.voxmlx.displayName])
        XCTAssertEqual(modelPreparer.prepareCalls.map(\.backendID), [BackendCatalog.voxmlx.id])

        try await manager.ensureReady(dictation: true, polishing: true)
        // Set + count, not positional (concurrent ensure tasks): exactly one
        // creation/prepare per backend, voxmlx not re-done by the second call.
        XCTAssertEqual(
            Set(supervisorFactory.createdConfigurations.map(\.name)),
            [BackendCatalog.voxmlx.displayName, BackendCatalog.polishd.displayName]
        )
        XCTAssertEqual(supervisorFactory.createdConfigurations.count, 2)
        XCTAssertEqual(
            Set(modelPreparer.prepareCalls.map(\.backendID)),
            [BackendCatalog.voxmlx.id, BackendCatalog.polishd.id]
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

    func testBundledPolishingBackendNeverEntersInstallPathEvenIfInstallerClaimsNeed() async throws {
        // The guard must be structural (installKind), not data-driven: even a
        // (mis)configured installer that claims the bundled backend needs an
        // install must never be invoked for it — the real installer traps on
        // bundled installs.
        let installer = FakeBackendInstaller(needsInstall: [BackendCatalog.polishd.id])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: false, polishing: true)

        XCTAssertTrue(installer.installCalls.isEmpty)
        XCTAssertEqual(manager.polishdStatus, .ready)
    }

    func testPolishingOnlyEnsureReadyDoesNotTouchVoxmlx() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(
            installer: installer,
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: false, polishing: true)

        XCTAssertEqual(supervisorFactory.createdConfigurations.map(\.name), [BackendCatalog.polishd.displayName])
        XCTAssertEqual(modelPreparer.prepareCalls.map(\.backendID), [BackendCatalog.polishd.id])
        XCTAssertEqual(manager.voxmlxStatus, .stopped)
        XCTAssertEqual(manager.polishdStatus, .ready)
    }

    func testConcurrentEnsureReadyDoesNotDoubleInstall() async throws {
        let installer = FakeBackendInstaller(
            needsInstall: [BackendCatalog.voxmlx.id],
            suspendInstalls: true
        )
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        let first = Task { @MainActor in
            try await manager.ensureReady(dictation: true, polishing: false)
        }
        await installer.waitUntilInstallStarted()

        let second = Task { @MainActor in
            try await manager.ensureReady(dictation: true, polishing: false)
        }
        await Task.yield()

        XCTAssertEqual(installer.installCalls.map(\.id), [BackendCatalog.voxmlx.id])
        installer.resumeInstall()

        try await first.value
        try await second.value
        XCTAssertEqual(installer.installCalls.map(\.id), [BackendCatalog.voxmlx.id])
        XCTAssertEqual(manager.voxmlxStatus, .ready)
    }

    func testStopAllStopsBothSupervisors() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: true, polishing: true)
        await manager.stopAll()

        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.voxmlx.displayName]?.stopCallCount, 1)
        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.polishd.displayName]?.stopCallCount, 1)
        XCTAssertEqual(manager.voxmlxStatus, .stopped)
        XCTAssertEqual(manager.polishdStatus, .stopped)
    }

    func testStopPolishingStopsOnlyPolishd() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: true, polishing: true)
        XCTAssertEqual(manager.voxmlxStatus, .ready)
        XCTAssertEqual(manager.polishdStatus, .ready)

        await manager.stopPolishing()

        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.polishd.displayName]?.stopCallCount, 1)
        XCTAssertEqual(manager.polishdStatus, .stopped)
        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.voxmlx.displayName]?.stopCallCount, 0)
        XCTAssertEqual(manager.voxmlxStatus, .ready)
    }

    func testModelChangeStopsSupervisorAndNextEnsureUsesNewModel() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let settings = SettingsStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        let manager = makeManager(
            installer: installer,
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
    }

    func testStopPolishingAwaitsCancelledEnsureSoASubsequentEnsureStartsFresh() async throws {
        // Field regression (PR #99): stop cancelled the in-flight ensure but
        // returned without awaiting it, so a model switch mid-download started
        // a second downloader process while the first was still terminating —
        // both writing the same HF cache blob. Stop must not return until the
        // cancelled ensure (and its downloader) fully unwound.
        let installer = FakeBackendInstaller(needsInstall: [])
        let modelPreparer = FakeModelPreparer(suspendBackendIDs: [BackendCatalog.polishd.id])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(
            installer: installer,
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

    func testStopDictationStopsOnlyVoxmlx() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: true, polishing: true)
        XCTAssertEqual(manager.voxmlxStatus, .ready)
        XCTAssertEqual(manager.polishdStatus, .ready)

        await manager.stopDictation()

        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.voxmlx.displayName]?.stopCallCount, 1)
        XCTAssertEqual(manager.voxmlxStatus, .stopped)
        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.polishd.displayName]?.stopCallCount, 0)
        XCTAssertEqual(manager.polishdStatus, .ready)
    }

    func testSupervisorStateMirrorMarksLaterFailureAndNextEnsureDoesNotShortCircuit() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: true, polishing: false)
        let supervisor = try XCTUnwrap(supervisorFactory.supervisors[BackendCatalog.voxmlx.displayName])
        XCTAssertEqual(manager.voxmlxStatus, .ready)
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
            if update.spec.id == BackendCatalog.voxmlx.id, case .failed = update.status {
                break
            }
        }

        XCTAssertEqual(manager.voxmlxStatus, .failed(summary: "process crashed after readiness", detail: nil))

        try await manager.ensureReady(dictation: true, polishing: false)

        XCTAssertEqual(supervisor.startCallCount, 2)
        XCTAssertEqual(manager.voxmlxStatus, .ready)
    }

    func testManagedBackendConfigurationsUseLongFirstRunReadinessTimeouts() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: true, polishing: true)

        // Keyed by backend, not positional: the two ensure tasks run
        // concurrently, so their creation order is not a contract.
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: supervisorFactory.createdConfigurations
                    .map { ($0.name, $0.readinessTimeout) }
            ),
            [
                // voxmlx still downloads its model inside the server on first
                // run; the bundled polishing helper only loads pre-downloaded
                // weights.
                BackendCatalog.voxmlx.displayName: .seconds(1800),
                BackendCatalog.polishd.displayName: .seconds(300),
            ]
        )
    }

    func testEnsureReadySurfacesModelPreparationBeforeStarting() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let modelPreparer = FakeModelPreparer(
            scriptedProgress: [
                BackendCatalog.voxmlx.id: [
                    ModelDownloadProgress(downloadedBytes: 0, totalBytes: 100),
                    ModelDownloadProgress(downloadedBytes: 40, totalBytes: 100),
                ],
            ]
        )
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        let manager = makeManager(
            installer: installer,
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )
        var voxmlxStatuses: [ManagedBackendStatus] = []
        manager.debugStatusChangeSink = { spec, status in
            guard spec.id == BackendCatalog.voxmlx.id else { return }
            voxmlxStatuses.append(status)
        }

        try await manager.ensureReady(dictation: true, polishing: false)

        XCTAssertEqual(
            modelPreparer.prepareCalls.map(\.repoID),
            [SettingsStore.RealtimeProvider.realtimeAPI.defaultModelName]
        )
        XCTAssertTrue(voxmlxStatuses.contains(.preparingModel(progress: ModelDownloadProgress(downloadedBytes: 40, totalBytes: 100))))
        XCTAssertTrue(voxmlxStatuses.contains(.starting))
        XCTAssertEqual(voxmlxStatuses.last, .ready)
        XCTAssertLessThan(
            try XCTUnwrap(voxmlxStatuses.firstIndex(of: .preparingModel(progress: ModelDownloadProgress(downloadedBytes: 40, totalBytes: 100)))),
            try XCTUnwrap(voxmlxStatuses.firstIndex(of: .starting))
        )
    }

    func testEnsureReadyWithPolishingPreparesBothModels() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(
            installer: installer,
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
                BackendCatalog.voxmlx.id: SettingsStore.RealtimeProvider.realtimeAPI.defaultModelName,
                BackendCatalog.polishd.id: SettingsStore.defaultLLMPolishingModel,
            ]
        )
    }

    func testEnsureReadyWithoutPolishingPreparesOnlyVoxmlx() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(
            installer: installer,
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: true, polishing: false)

        XCTAssertEqual(modelPreparer.prepareCalls.map(\.backendID), [BackendCatalog.voxmlx.id])
        XCTAssertEqual(supervisorFactory.createdConfigurations.map(\.name), [BackendCatalog.voxmlx.displayName])
    }

    func testCancellingEnsureReadyDuringModelPreparationTerminatesAndDoesNotMarkReady() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let modelPreparer = FakeModelPreparer(suspendBackendIDs: [BackendCatalog.voxmlx.id])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        let manager = makeManager(
            installer: installer,
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

        XCTAssertEqual(modelPreparer.terminatedBackendIDs, [BackendCatalog.voxmlx.id])
        XCTAssertTrue(supervisorFactory.createdConfigurations.isEmpty)
        XCTAssertEqual(manager.voxmlxStatus, .stopped)
    }

    func testStopPolishingCancelsInFlightEnsureBeforeSupervisorCanStart() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let modelPreparer = FakeModelPreparer(suspendBackendIDs: [BackendCatalog.polishd.id])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(
            installer: installer,
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
        let installer = FakeBackendInstaller(needsInstall: [])
        let modelPreparer = FakeModelPreparer(
            failures: [
                BackendCatalog.voxmlx.id: ModelDownloadError.downloaderReportedError(
                    message: "Hugging Face rejected the request.",
                    stderrTail: "stderr \(marker)"
                ),
            ]
        )
        let manager = makeManager(
            installer: installer,
            modelPreparer: modelPreparer,
            supervisorFactory: FakeSupervisorFactory()
        )

        do {
            try await manager.ensureReady(dictation: true, polishing: false)
            XCTFail("expected ensureReady to throw")
        } catch let error as ManagedBackendManagerError {
            XCTAssertEqual(error.localizedDescription, "voxmlx failed: Hugging Face rejected the request.")
            XCTAssertEqual(error.technicalDetails, "stderr \(marker)")
        } catch {
            XCTFail("expected ManagedBackendManagerError, got \(error)")
        }

        XCTAssertEqual(
            manager.voxmlxStatus,
            .failed(summary: "Hugging Face rejected the request.", detail: "stderr \(marker)")
        )
    }

    func testSupervisorFailureErrorSplitsSummaryFromTechnicalDetails() async throws {
        let marker = "FAKE_STDERR_TRACEBACK"
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [
            .failed(
                summary: "polishd exited 5 consecutive times.",
                detail: "stderr: traceback \(marker)"
            ),
        ]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

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
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        // voxmlx never reaches .running: its ensure blocks awaiting readiness.
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = []
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        let stuckDictation = Task { try await manager.ensureReady(dictation: true, polishing: false) }
        while supervisorFactory.supervisors[BackendCatalog.voxmlx.displayName]?.startCallCount != 1 {
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
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.polishd.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        // First dictation: polishing disabled at the time.
        try await manager.ensureReady(dictation: true, polishing: false)
        XCTAssertEqual(manager.voxmlxStatus, .ready)
        XCTAssertEqual(manager.polishdStatus, .stopped)

        // User enables polishing, dictates again: polishd must come up now.
        try await manager.ensureReady(dictation: true, polishing: true)
        XCTAssertEqual(manager.polishdStatus, .ready)
        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.polishd.displayName]?.startCallCount, 1)
    }

    private func makeManager(
        installer: FakeBackendInstaller,
        modelPreparer: FakeModelPreparer = FakeModelPreparer(),
        polishingModelProvider: @escaping BackendManager.PolishingModelProvider = {
            SettingsStore.defaultLLMPolishingModel
        },
        supervisorFactory: FakeSupervisorFactory
    ) -> BackendManager {
        BackendManager(
            installer: installer,
            modelPreparer: modelPreparer,
            layout: BackendInstallLayout(root: URL(fileURLWithPath: "/tmp/localvoxtral-backend-manager-tests")),
            polishingModelProvider: polishingModelProvider,
            supervisorFactory: { configuration in
                supervisorFactory.makeSupervisor(configuration: configuration)
            }
        )
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
}

// Same concurrent-callers shape as FakeModelPreparer: `install` runs off the
// main actor, so all mutable state sits behind a Mutex.
private final class FakeBackendInstaller: BackendInstalling, @unchecked Sendable {
    private struct State {
        var needsInstall: Set<String>
        var installCalls: [ManagedBackendSpec] = []
        var installStartedContinuation: CheckedContinuation<Void, Never>?
        var installResumeContinuation: CheckedContinuation<Void, Never>?
    }

    private let installFailures: [String: Error]
    private let suspendInstalls: Bool
    private let state: Mutex<State>

    var installCalls: [ManagedBackendSpec] { state.withLock { $0.installCalls } }

    init(
        needsInstall: Set<String>,
        installFailures: [String: Error] = [:],
        suspendInstalls: Bool = false
    ) {
        self.installFailures = installFailures
        self.suspendInstalls = suspendInstalls
        self.state = Mutex(State(needsInstall: needsInstall))
    }

    func needsInstallOrUpdate(_ spec: ManagedBackendSpec) -> Bool {
        state.withLock { $0.needsInstall.contains(spec.id) }
    }

    func install(
        _ spec: ManagedBackendSpec,
        progress: @MainActor @Sendable @escaping (BackendInstallProgress) -> Void
    ) async throws {
        let started: CheckedContinuation<Void, Never>? = state.withLock {
            $0.installCalls.append(spec)
            let continuation = $0.installStartedContinuation
            $0.installStartedContinuation = nil
            return continuation
        }
        started?.resume()

        if suspendInstalls {
            await withCheckedContinuation { continuation in
                state.withLock { $0.installResumeContinuation = continuation }
            }
        }

        if let error = installFailures[spec.id] {
            throw error
        }

        await progress(.verifying)
        await progress(.installing(logLine: "installed \(spec.displayName)"))
        await progress(.finished)
        state.withLock { _ = $0.needsInstall.remove(spec.id) }
    }

    func waitUntilInstallStarted() async {
        await withCheckedContinuation { continuation in
            let alreadyStarted: Bool = state.withLock {
                if $0.installCalls.isEmpty {
                    $0.installStartedContinuation = continuation
                    return false
                }
                return true
            }
            if alreadyStarted {
                continuation.resume()
            }
        }
    }

    func resumeInstall() {
        let continuation: CheckedContinuation<Void, Never>? = state.withLock {
            let continuation = $0.installResumeContinuation
            $0.installResumeContinuation = nil
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

private struct FakeBackendError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
