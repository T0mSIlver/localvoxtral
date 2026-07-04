import Darwin
import Foundation
import Observation

enum ManagedBackendStatus: Equatable {
    case notInstalled
    case installing(progress: BackendInstallProgress)
    case starting
    case ready
    case stopped
    case failed(message: String)

    var requiresInstallProgressText: Bool {
        switch self {
        case .notInstalled, .installing:
            return true
        case .starting, .ready, .stopped, .failed:
            return false
        }
    }
}

enum ManagedBackendManagerError: LocalizedError {
    case backendFailed(name: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .backendFailed(let name, let detail):
            return "\(name) failed: \(detail)"
        }
    }
}

@MainActor
protocol ManagedBackendSupervising: AnyObject {
    var state: BackendProcessSupervisor.State { get }
    var stateUpdates: AsyncStream<BackendProcessSupervisor.State> { get }

    func start() async
    func stop() async
}

extension BackendProcessSupervisor: ManagedBackendSupervising {}

@MainActor
protocol ManagedBackendManaging: AnyObject {
    var voxmlxStatus: ManagedBackendStatus { get }
    var mlxLMStatus: ManagedBackendStatus { get }

    func ensureReady(includePolishing: Bool) async throws
    func stopAll() async
}

@MainActor
@Observable
final class BackendManager: ManagedBackendManaging {
    typealias SupervisorFactory = @MainActor (BackendProcessConfiguration) -> any ManagedBackendSupervising

    private(set) var voxmlxStatus: ManagedBackendStatus
    private(set) var mlxLMStatus: ManagedBackendStatus

    @ObservationIgnored private let installer: any BackendInstalling
    @ObservationIgnored private let layout: BackendInstallLayout
    @ObservationIgnored private let supervisorFactory: SupervisorFactory
    @ObservationIgnored private var voxmlxSupervisor: (any ManagedBackendSupervising)?
    @ObservationIgnored private var mlxLMSupervisor: (any ManagedBackendSupervising)?
    @ObservationIgnored private var ensureReadyTask: Task<Void, Error>?
    #if DEBUG
    @ObservationIgnored var debugStatusChangeSink: ((ManagedBackendSpec, ManagedBackendStatus) -> Void)?
    #endif

    init(
        installer: any BackendInstalling = BackendInstaller(),
        layout: BackendInstallLayout = BackendInstallLayout(),
        supervisorFactory: @escaping SupervisorFactory = { configuration in
            BackendProcessSupervisor(configuration: configuration)
        }
    ) {
        self.installer = installer
        self.layout = layout
        self.supervisorFactory = supervisorFactory
        self.voxmlxStatus = installer.needsInstallOrUpdate(BackendCatalog.voxmlx)
            ? .notInstalled
            : .stopped
        self.mlxLMStatus = installer.needsInstallOrUpdate(BackendCatalog.mlxLM)
            ? .notInstalled
            : .stopped
    }

    func ensureReady(includePolishing: Bool) async throws {
        while true {
            if let ensureReadyTask {
                try await ensureReadyTask.value
                if includePolishing, !isReady(BackendCatalog.mlxLM) {
                    continue
                }
                return
            }

            let task = Task { @MainActor in
                try await self.performEnsureReady(includePolishing: includePolishing)
            }
            ensureReadyTask = task
            do {
                try await task.value
                ensureReadyTask = nil
                return
            } catch {
                ensureReadyTask = nil
                throw error
            }
        }
    }

    func stopAll() async {
        await voxmlxSupervisor?.stop()
        await mlxLMSupervisor?.stop()
        if voxmlxSupervisor != nil {
            voxmlxStatus = .stopped
        }
        if mlxLMSupervisor != nil {
            mlxLMStatus = .stopped
        }
    }

    func status(for spec: ManagedBackendSpec) -> ManagedBackendStatus {
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            return voxmlxStatus
        case BackendCatalog.mlxLM.id:
            return mlxLMStatus
        default:
            return .failed(message: "Unknown managed backend '\(spec.id)'.")
        }
    }

    private func performEnsureReady(includePolishing: Bool) async throws {
        try await ensureReady(BackendCatalog.voxmlx)
        if includePolishing {
            try await ensureReady(BackendCatalog.mlxLM)
        }
    }

    private func ensureReady(_ spec: ManagedBackendSpec) async throws {
        if isReady(spec) {
            setStatus(.ready, for: spec)
            return
        }

        if installer.needsInstallOrUpdate(spec) {
            setStatus(.installing(progress: .downloading(fraction: nil)), for: spec)
            do {
                try await installer.install(spec) { [weak self] progress in
                    guard let self else { return }
                    self.setStatus(.installing(progress: progress), for: spec)
                }
            } catch {
                let detail = error.localizedDescription
                setStatus(.failed(message: detail), for: spec)
                throw ManagedBackendManagerError.backendFailed(
                    name: spec.displayName,
                    detail: detail
                )
            }
        }

        setStatus(.starting, for: spec)
        let supervisor = supervisor(for: spec)
        try await startAndWaitUntilReady(supervisor, spec: spec)
    }

    private func startAndWaitUntilReady(
        _ supervisor: any ManagedBackendSupervising,
        spec: ManagedBackendSpec
    ) async throws {
        let updates = supervisor.stateUpdates
        await supervisor.start()

        switch supervisor.state {
        case .running:
            setStatus(.ready, for: spec)
            return
        case .failed(let message):
            setStatus(.failed(message: message), for: spec)
            throw ManagedBackendManagerError.backendFailed(name: spec.displayName, detail: message)
        default:
            break
        }

        for await state in updates {
            switch state {
            case .launching, .waitingForReady, .restarting:
                setStatus(.starting, for: spec)
            case .running:
                setStatus(.ready, for: spec)
                return
            case .failed(let message):
                setStatus(.failed(message: message), for: spec)
                throw ManagedBackendManagerError.backendFailed(name: spec.displayName, detail: message)
            case .stopped:
                let message = "\(spec.displayName) stopped before it became ready."
                setStatus(.failed(message: message), for: spec)
                throw ManagedBackendManagerError.backendFailed(name: spec.displayName, detail: message)
            case .idle:
                break
            }
        }

        let message = "\(spec.displayName) stopped reporting status before it became ready."
        setStatus(.failed(message: message), for: spec)
        throw ManagedBackendManagerError.backendFailed(name: spec.displayName, detail: message)
    }

    private func supervisor(for spec: ManagedBackendSpec) -> any ManagedBackendSupervising {
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            if let voxmlxSupervisor { return voxmlxSupervisor }
            let supervisor = supervisorFactory(configuration(for: spec))
            voxmlxSupervisor = supervisor
            return supervisor
        case BackendCatalog.mlxLM.id:
            if let mlxLMSupervisor { return mlxLMSupervisor }
            let supervisor = supervisorFactory(configuration(for: spec))
            mlxLMSupervisor = supervisor
            return supervisor
        default:
            preconditionFailure("Unknown managed backend '\(spec.id)'.")
        }
    }

    private func configuration(for spec: ManagedBackendSpec) -> BackendProcessConfiguration {
        BackendProcessConfiguration(
            name: spec.displayName,
            executableURL: layout.toolBin.appendingPathComponent(spec.executableName),
            arguments: arguments(for: spec),
            environment: processEnvironment(),
            readinessURL: URL(string: "http://127.0.0.1:\(spec.port)/health")!
        )
    }

    private func arguments(for spec: ManagedBackendSpec) -> [String] {
        let parentPID = "\(Darwin.getpid())"
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            return [
                "--model",
                SettingsStore.RealtimeProvider.realtimeAPI.defaultModelName,
                "--port",
                "\(spec.port)",
                "--parent-pid",
                parentPID,
            ]
        case BackendCatalog.mlxLM.id:
            // Prompt caching avoids reprocessing the full polishing prompt on
            // every request — the mlx-lm fork's main optimization (~50% faster
            // prompt processing on M1 Pro with the default prompts).
            return [
                "--model",
                SettingsStore.defaultLLMPolishingModel,
                "--port",
                "\(spec.port)",
                "--parent-pid",
                parentPID,
                "--prompt-cache-size",
                "1",
                "--prompt-cache-bytes",
                "1GB",
            ]
        default:
            return []
        }
    }

    private func processEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["PATH", "HOME"] {
            if let value = inherited[key] {
                environment[key] = value
            }
        }
        environment.merge(layout.environment) { _, new in new }
        return environment
    }

    private func isReady(_ spec: ManagedBackendSpec) -> Bool {
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            return voxmlxSupervisor?.state == .running || voxmlxStatus == .ready
        case BackendCatalog.mlxLM.id:
            return mlxLMSupervisor?.state == .running || mlxLMStatus == .ready
        default:
            return false
        }
    }

    private func setStatus(_ status: ManagedBackendStatus, for spec: ManagedBackendSpec) {
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            voxmlxStatus = status
        case BackendCatalog.mlxLM.id:
            mlxLMStatus = status
        default:
            break
        }
        #if DEBUG
        debugStatusChangeSink?(spec, status)
        #endif
    }
}
