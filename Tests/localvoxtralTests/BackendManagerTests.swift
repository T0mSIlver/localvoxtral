import Foundation
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

    func testPolishingFlagControlsWhetherMLXLMIsTouched() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [.running]
        let manager = makeManager(
            installer: installer,
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: true, polishing: false)
        XCTAssertEqual(supervisorFactory.createdConfigurations.map(\.name), [BackendCatalog.voxmlx.displayName])
        XCTAssertEqual(modelPreparer.prepareCalls.map(\.backendID), [BackendCatalog.voxmlx.id])

        try await manager.ensureReady(dictation: true, polishing: true)
        XCTAssertEqual(
            supervisorFactory.createdConfigurations.map(\.name),
            [BackendCatalog.voxmlx.displayName, BackendCatalog.mlxLM.displayName]
        )
        XCTAssertEqual(
            modelPreparer.prepareCalls.map(\.backendID),
            [BackendCatalog.voxmlx.id, BackendCatalog.mlxLM.id]
        )
        XCTAssertEqual(manager.mlxLMStatus, .ready)

        let mlxLMConfiguration = try XCTUnwrap(
            supervisorFactory.createdConfigurations
                .first { $0.name == BackendCatalog.mlxLM.displayName }
        )
        // The bundled helper owns prompt handling internally; the supervisor
        // contract is model id + port + parent-pid tethering.
        XCTAssertTrue(mlxLMConfiguration.arguments.contains("--parent-pid"))
        XCTAssertEqual(
            mlxLMConfiguration.arguments.prefix(2),
            ["--model", SettingsStore.defaultLLMPolishingModel]
        )
        XCTAssertFalse(mlxLMConfiguration.arguments.contains("--prompt-cache-size"))
        // The bundled executable resolves next to the app binary, never from
        // the uv tools tree.
        XCTAssertEqual(
            mlxLMConfiguration.executableURL.lastPathComponent,
            BackendCatalog.mlxLM.executableName
        )
        XCTAssertFalse(mlxLMConfiguration.executableURL.path.contains("backends"))
    }

    func testPolishingOnlyEnsureReadyDoesNotTouchVoxmlx() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [.running]
        let manager = makeManager(
            installer: installer,
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: false, polishing: true)

        XCTAssertEqual(supervisorFactory.createdConfigurations.map(\.name), [BackendCatalog.mlxLM.displayName])
        XCTAssertEqual(modelPreparer.prepareCalls.map(\.backendID), [BackendCatalog.mlxLM.id])
        XCTAssertEqual(manager.voxmlxStatus, .stopped)
        XCTAssertEqual(manager.mlxLMStatus, .ready)
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
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: true, polishing: true)
        await manager.stopAll()

        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.voxmlx.displayName]?.stopCallCount, 1)
        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.mlxLM.displayName]?.stopCallCount, 1)
        XCTAssertEqual(manager.voxmlxStatus, .stopped)
        XCTAssertEqual(manager.mlxLMStatus, .stopped)
    }

    func testStopPolishingStopsOnlyMLXLM() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: true, polishing: true)
        XCTAssertEqual(manager.voxmlxStatus, .ready)
        XCTAssertEqual(manager.mlxLMStatus, .ready)

        await manager.stopPolishing()

        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.mlxLM.displayName]?.stopCallCount, 1)
        XCTAssertEqual(manager.mlxLMStatus, .stopped)
        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.voxmlx.displayName]?.stopCallCount, 0)
        XCTAssertEqual(manager.voxmlxStatus, .ready)
    }

    func testStopDictationStopsOnlyVoxmlx() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: true, polishing: true)
        XCTAssertEqual(manager.voxmlxStatus, .ready)
        XCTAssertEqual(manager.mlxLMStatus, .ready)

        await manager.stopDictation()

        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.voxmlx.displayName]?.stopCallCount, 1)
        XCTAssertEqual(manager.voxmlxStatus, .stopped)
        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.mlxLM.displayName]?.stopCallCount, 0)
        XCTAssertEqual(manager.mlxLMStatus, .ready)
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

        supervisor.emit(.failed(summary: "process crashed after readiness", detail: nil))
        await Task.yield()

        XCTAssertEqual(manager.voxmlxStatus, .failed(summary: "process crashed after readiness", detail: nil))

        try await manager.ensureReady(dictation: true, polishing: false)

        XCTAssertEqual(supervisor.startCallCount, 2)
        XCTAssertEqual(manager.voxmlxStatus, .ready)
    }

    func testManagedBackendConfigurationsUseLongFirstRunReadinessTimeouts() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        try await manager.ensureReady(dictation: true, polishing: true)

        XCTAssertEqual(
            supervisorFactory.createdConfigurations.map(\.readinessTimeout),
            // voxmlx still downloads its model inside the server on first run;
            // the bundled polishing helper only loads pre-downloaded weights.
            [.seconds(1800), .seconds(300)]
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
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [.running]
        let manager = makeManager(
            installer: installer,
            modelPreparer: modelPreparer,
            supervisorFactory: supervisorFactory
        )

        try await manager.ensureReady(dictation: true, polishing: true)

        XCTAssertEqual(
            modelPreparer.prepareCalls.map(\.backendID),
            [BackendCatalog.voxmlx.id, BackendCatalog.mlxLM.id]
        )
        XCTAssertEqual(
            modelPreparer.prepareCalls.map(\.repoID),
            [
                SettingsStore.RealtimeProvider.realtimeAPI.defaultModelName,
                SettingsStore.defaultLLMPolishingModel,
            ]
        )
    }

    func testEnsureReadyWithoutPolishingPreparesOnlyVoxmlx() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let modelPreparer = FakeModelPreparer()
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [.running]
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
        let modelPreparer = FakeModelPreparer(suspendBackendIDs: [BackendCatalog.mlxLM.id])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [.running]
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

        XCTAssertEqual(modelPreparer.terminatedBackendIDs, [BackendCatalog.mlxLM.id])
        XCTAssertTrue(supervisorFactory.createdConfigurations.isEmpty)
        XCTAssertEqual(manager.mlxLMStatus, .stopped)
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
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [
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
            manager.mlxLMStatus,
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
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        let stuckDictation = Task { try await manager.ensureReady(dictation: true, polishing: false) }
        while supervisorFactory.supervisors[BackendCatalog.voxmlx.displayName]?.startCallCount != 1 {
            await Task.yield()
        }

        // Field regression (2026-07-04): with one shared single-flight slot,
        // this joined the stuck dictation run — whose flags never covered
        // polishing — and silently never started mlx-lm.
        try await manager.ensureReady(dictation: false, polishing: true)
        XCTAssertEqual(manager.mlxLMStatus, .ready)
        XCTAssertEqual(
            supervisorFactory.supervisors[BackendCatalog.mlxLM.displayName]?.startCallCount, 1
        )

        stuckDictation.cancel()
        _ = try? await stuckDictation.value
    }

    func testSecondEnsureReadyAddsPolishingAfterDictationOnlyRun() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        // First dictation: polishing disabled at the time.
        try await manager.ensureReady(dictation: true, polishing: false)
        XCTAssertEqual(manager.voxmlxStatus, .ready)
        XCTAssertEqual(manager.mlxLMStatus, .stopped)

        // User enables polishing, dictates again: mlx-lm must come up now.
        try await manager.ensureReady(dictation: true, polishing: true)
        XCTAssertEqual(manager.mlxLMStatus, .ready)
        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.mlxLM.displayName]?.startCallCount, 1)
    }

    private func makeManager(
        installer: FakeBackendInstaller,
        modelPreparer: FakeModelPreparer = FakeModelPreparer(),
        supervisorFactory: FakeSupervisorFactory
    ) -> BackendManager {
        BackendManager(
            installer: installer,
            modelPreparer: modelPreparer,
            layout: BackendInstallLayout(root: URL(fileURLWithPath: "/tmp/localvoxtral-backend-manager-tests")),
            supervisorFactory: { configuration in
                supervisorFactory.makeSupervisor(configuration: configuration)
            }
        )
    }
}

private final class FakeModelPreparer: ModelPreparing, @unchecked Sendable {
    private let scriptedProgress: [String: [ModelDownloadProgress]]
    private let failures: [String: Error]
    private let suspendBackendIDs: Set<String>
    private var prepareStartedContinuation: CheckedContinuation<Void, Never>?
    private var prepareResumeContinuation: CheckedContinuation<Void, Error>?

    private(set) var prepareCalls: [ModelPreparationRequest] = []
    private(set) var terminatedBackendIDs: [String] = []

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
        prepareCalls.append(request)
        prepareStartedContinuation?.resume()
        prepareStartedContinuation = nil

        for event in scriptedProgress[request.backendID] ?? [] {
            await progress(event)
        }

        if suspendBackendIDs.contains(request.backendID) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    prepareResumeContinuation = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.terminatedBackendIDs.append(request.backendID)
                    self?.prepareResumeContinuation?.resume(throwing: CancellationError())
                    self?.prepareResumeContinuation = nil
                }
            }
        }

        if let failure = failures[request.backendID] {
            throw failure
        }
    }

    func waitUntilPrepareStarted() async {
        guard prepareCalls.isEmpty else { return }
        await withCheckedContinuation { continuation in
            prepareStartedContinuation = continuation
        }
    }
}

private final class FakeBackendInstaller: BackendInstalling, @unchecked Sendable {
    private var needsInstall: Set<String>
    private let installFailures: [String: Error]
    private let suspendInstalls: Bool
    private var installStartedContinuation: CheckedContinuation<Void, Never>?
    private var installResumeContinuation: CheckedContinuation<Void, Never>?

    private(set) var installCalls: [ManagedBackendSpec] = []

    init(
        needsInstall: Set<String>,
        installFailures: [String: Error] = [:],
        suspendInstalls: Bool = false
    ) {
        self.needsInstall = needsInstall
        self.installFailures = installFailures
        self.suspendInstalls = suspendInstalls
    }

    func needsInstallOrUpdate(_ spec: ManagedBackendSpec) -> Bool {
        needsInstall.contains(spec.id)
    }

    func install(
        _ spec: ManagedBackendSpec,
        progress: @MainActor @Sendable @escaping (BackendInstallProgress) -> Void
    ) async throws {
        installCalls.append(spec)
        installStartedContinuation?.resume()
        installStartedContinuation = nil

        if suspendInstalls {
            await withCheckedContinuation { continuation in
                installResumeContinuation = continuation
            }
        }

        if let error = installFailures[spec.id] {
            throw error
        }

        await progress(.verifying)
        await progress(.installing(logLine: "installed \(spec.displayName)"))
        await progress(.finished)
        needsInstall.remove(spec.id)
    }

    func waitUntilInstallStarted() async {
        guard installCalls.isEmpty else { return }
        await withCheckedContinuation { continuation in
            installStartedContinuation = continuation
        }
    }

    func resumeInstall() {
        installResumeContinuation?.resume()
        installResumeContinuation = nil
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
