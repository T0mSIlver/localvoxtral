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

        try await manager.ensureReady(includePolishing: false)

        XCTAssertEqual(installer.installCalls.map(\.id), [BackendCatalog.voxmlx.id])
        XCTAssertEqual(manager.voxmlxStatus, .ready)
        XCTAssertTrue(voxmlxStatuses.contains(.installing(progress: .downloading(fraction: nil))))
        XCTAssertTrue(voxmlxStatuses.contains(.installing(progress: .verifying)))
        XCTAssertTrue(voxmlxStatuses.contains(.starting))
        XCTAssertEqual(voxmlxStatuses.last, .ready)
    }

    func testAlreadyInstalledSkipsInstaller() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        try await manager.ensureReady(includePolishing: false)

        XCTAssertTrue(installer.installCalls.isEmpty)
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
            try await manager.ensureReady(includePolishing: false)
            XCTFail("expected ensureReady to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("voxmlx"))
            XCTAssertTrue(error.localizedDescription.contains("wheel unavailable"))
        }

        XCTAssertEqual(manager.voxmlxStatus, .failed(summary: "wheel unavailable", detail: nil))
    }

    func testPolishingFlagControlsWhetherMLXLMIsTouched() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        try await manager.ensureReady(includePolishing: false)
        XCTAssertEqual(supervisorFactory.createdConfigurations.map(\.name), [BackendCatalog.voxmlx.displayName])

        try await manager.ensureReady(includePolishing: true)
        XCTAssertEqual(
            supervisorFactory.createdConfigurations.map(\.name),
            [BackendCatalog.voxmlx.displayName, BackendCatalog.mlxLM.displayName]
        )
        XCTAssertEqual(manager.mlxLMStatus, .ready)

        let mlxLMArguments = try XCTUnwrap(
            supervisorFactory.createdConfigurations
                .first { $0.name == BackendCatalog.mlxLM.displayName }?
                .arguments
        )
        // The managed server must run with the fork's prompt caching enabled;
        // the README's polishing-latency claim depends on these flags.
        XCTAssertTrue(mlxLMArguments.contains("--prompt-cache-size"))
        XCTAssertTrue(mlxLMArguments.contains("--prompt-cache-bytes"))
        XCTAssertTrue(mlxLMArguments.contains("--parent-pid"))
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
            try await manager.ensureReady(includePolishing: false)
        }
        await installer.waitUntilInstallStarted()

        let second = Task { @MainActor in
            try await manager.ensureReady(includePolishing: false)
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

        try await manager.ensureReady(includePolishing: true)
        await manager.stopAll()

        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.voxmlx.displayName]?.stopCallCount, 1)
        XCTAssertEqual(supervisorFactory.supervisors[BackendCatalog.mlxLM.displayName]?.stopCallCount, 1)
        XCTAssertEqual(manager.voxmlxStatus, .stopped)
        XCTAssertEqual(manager.mlxLMStatus, .stopped)
    }

    func testSupervisorStateMirrorMarksLaterFailureAndNextEnsureDoesNotShortCircuit() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        try await manager.ensureReady(includePolishing: false)
        let supervisor = try XCTUnwrap(supervisorFactory.supervisors[BackendCatalog.voxmlx.displayName])
        XCTAssertEqual(manager.voxmlxStatus, .ready)
        XCTAssertEqual(supervisor.startCallCount, 1)

        supervisor.emit(.failed(summary: "process crashed after readiness", detail: nil))
        await Task.yield()

        XCTAssertEqual(manager.voxmlxStatus, .failed(summary: "process crashed after readiness", detail: nil))

        try await manager.ensureReady(includePolishing: false)

        XCTAssertEqual(supervisor.startCallCount, 2)
        XCTAssertEqual(manager.voxmlxStatus, .ready)
    }

    func testManagedBackendConfigurationsUseLongFirstRunReadinessTimeouts() async throws {
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [.running]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        try await manager.ensureReady(includePolishing: true)

        XCTAssertEqual(
            supervisorFactory.createdConfigurations.map(\.readinessTimeout),
            [.seconds(1800), .seconds(1800)]
        )
    }

    func testSupervisorFailureErrorSplitsSummaryFromTechnicalDetails() async throws {
        let marker = "FAKE_STDERR_TRACEBACK"
        let installer = FakeBackendInstaller(needsInstall: [])
        let supervisorFactory = FakeSupervisorFactory()
        supervisorFactory.statesByName[BackendCatalog.voxmlx.displayName] = [.running]
        supervisorFactory.statesByName[BackendCatalog.mlxLM.displayName] = [
            .failed(
                summary: "mlx-lm exited 5 consecutive times.",
                detail: "stderr: Python traceback \(marker)"
            ),
        ]
        let manager = makeManager(installer: installer, supervisorFactory: supervisorFactory)

        do {
            try await manager.ensureReady(includePolishing: true)
            XCTFail("expected ensureReady to throw")
        } catch let error as ManagedBackendManagerError {
            XCTAssertEqual(
                error.localizedDescription,
                "mlx-lm failed: mlx-lm exited 5 consecutive times."
            )
            XCTAssertFalse(error.localizedDescription.contains(marker))
            XCTAssertTrue(error.technicalDetails?.contains(marker) == true)
        } catch {
            XCTFail("expected ManagedBackendManagerError, got \(error)")
        }

        XCTAssertEqual(
            manager.mlxLMStatus,
            .failed(
                summary: "mlx-lm exited 5 consecutive times.",
                detail: "stderr: Python traceback \(marker)"
            )
        )
    }

    private func makeManager(
        installer: FakeBackendInstaller,
        supervisorFactory: FakeSupervisorFactory
    ) -> BackendManager {
        BackendManager(
            installer: installer,
            layout: BackendInstallLayout(root: URL(fileURLWithPath: "/tmp/localvoxtral-backend-manager-tests")),
            supervisorFactory: { configuration in
                supervisorFactory.makeSupervisor(configuration: configuration)
            }
        )
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
