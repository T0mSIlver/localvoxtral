import Darwin
import Foundation
import Observation

struct ManagedBackendStatusUpdate: Equatable, Sendable {
    let spec: ManagedBackendSpec
    let status: ManagedBackendStatus
}

enum ManagedBackendStatus: Equatable, Sendable {
    case notInstalled
    case installing(progress: BackendInstallProgress)
    case preparingModel(progress: ModelDownloadProgress)
    case starting
    case ready
    case stopped
    case failed(summary: String, detail: String?)

    var requiresInstallProgressText: Bool {
        switch self {
        case .notInstalled, .installing:
            return true
        case .preparingModel, .starting, .ready, .stopped, .failed:
            return false
        }
    }
}

enum ManagedBackendManagerError: LocalizedError {
    case backendFailed(name: String, summary: String, detail: String?)

    var errorDescription: String? {
        switch self {
        case .backendFailed(let name, let summary, _):
            return "\(name) failed: \(summary)"
        }
    }

    var technicalDetails: String? {
        switch self {
        case .backendFailed(_, _, let detail):
            return detail
        }
    }

    var backendName: String {
        switch self {
        case .backendFailed(let name, _, _):
            return name
        }
    }
}

@MainActor
protocol ManagedBackendSupervising: AnyObject {
    var state: BackendProcessSupervisor.State { get }
    var stateUpdates: AsyncStream<BackendProcessSupervisor.State> { get }
    /// Ring buffer of recent stdout/stderr lines (capped by the supervisor).
    /// Surfaced for local diagnostics export only.
    var recentOutput: [String] { get }

    func start() async
    func stop() async
}

extension BackendProcessSupervisor: ManagedBackendSupervising {}

@MainActor
protocol ManagedBackendManaging: AnyObject {
    var voxmlxStatus: ManagedBackendStatus { get }
    var mlxLMStatus: ManagedBackendStatus { get }
    var statusUpdates: AsyncStream<ManagedBackendStatusUpdate> { get }

    func ensureReady(dictation: Bool, polishing: Bool) async throws
    func stopAll() async
    /// Stop only the managed voxmlx (dictation) process, leaving mlx-lm
    /// (polishing) untouched. A no-op if voxmlx was never started.
    func stopDictation() async
    /// Stop only the managed mlx-lm (polishing) process, leaving voxmlx
    /// (dictation) untouched. A no-op if mlx-lm was never started.
    func stopPolishing() async
    /// Recent supervisor output lines for the given backend, or empty if the
    /// supervisor has not been created yet (backend never started). For local
    /// diagnostics export only.
    func recentOutput(for spec: ManagedBackendSpec) -> [String]
}

@MainActor
@Observable
final class BackendManager: ManagedBackendManaging {
    typealias SupervisorFactory = @MainActor (BackendProcessConfiguration) -> any ManagedBackendSupervising

    private(set) var voxmlxStatus: ManagedBackendStatus
    private(set) var mlxLMStatus: ManagedBackendStatus

    @ObservationIgnored private let installer: any BackendInstalling
    @ObservationIgnored private let modelPreparer: any ModelPreparing
    @ObservationIgnored private let layout: BackendInstallLayout
    @ObservationIgnored private let supervisorFactory: SupervisorFactory
    @ObservationIgnored private var voxmlxSupervisor: (any ManagedBackendSupervising)?
    @ObservationIgnored private var mlxLMSupervisor: (any ManagedBackendSupervising)?
    @ObservationIgnored private var ensureReadyTask: Task<Void, Error>?
    @ObservationIgnored private var voxmlxStateMirrorTask: Task<Void, Never>?
    @ObservationIgnored private var mlxLMStateMirrorTask: Task<Void, Never>?
    @ObservationIgnored private var statusUpdateContinuations: [UUID: AsyncStream<ManagedBackendStatusUpdate>.Continuation] = [:]
    #if DEBUG
    @ObservationIgnored var debugStatusChangeSink: ((ManagedBackendSpec, ManagedBackendStatus) -> Void)?
    #endif

    init(
        installer: any BackendInstalling = BackendInstaller(),
        modelPreparer: (any ModelPreparing)? = nil,
        layout: BackendInstallLayout = BackendInstallLayout(),
        supervisorFactory: @escaping SupervisorFactory = { configuration in
            BackendProcessSupervisor(configuration: configuration)
        }
    ) {
        self.installer = installer
        self.layout = layout
        self.modelPreparer = modelPreparer ?? HFModelDownloader(layout: layout)
        self.supervisorFactory = supervisorFactory
        self.voxmlxStatus = installer.needsInstallOrUpdate(BackendCatalog.voxmlx)
            ? .notInstalled
            : .stopped
        self.mlxLMStatus = installer.needsInstallOrUpdate(BackendCatalog.mlxLM)
            ? .notInstalled
            : .stopped
    }

    var statusUpdates: AsyncStream<ManagedBackendStatusUpdate> {
        let id = UUID()
        let stream = AsyncStream<ManagedBackendStatusUpdate>.makeStream(of: ManagedBackendStatusUpdate.self)
        statusUpdateContinuations[id] = stream.continuation
        stream.continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.statusUpdateContinuations[id] = nil
            }
        }
        return stream.stream
    }

    func ensureReady(dictation: Bool, polishing: Bool) async throws {
        guard dictation || polishing else { return }
        while true {
            if let ensureReadyTask {
                try await awaitEnsureReadyTask(ensureReadyTask)
                if dictation, !isReady(BackendCatalog.voxmlx) {
                    continue
                }
                if polishing, !isReady(BackendCatalog.mlxLM) {
                    continue
                }
                return
            }

            let task = Task { @MainActor in
                try await self.performEnsureReady(dictation: dictation, polishing: polishing)
            }
            ensureReadyTask = task
            do {
                try await awaitEnsureReadyTask(task)
                ensureReadyTask = nil
                return
            } catch {
                ensureReadyTask = nil
                throw error
            }
        }
    }

    private func awaitEnsureReadyTask(_ task: Task<Void, Error>) async throws {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func stopAll() async {
        await voxmlxSupervisor?.stop()
        await mlxLMSupervisor?.stop()
        voxmlxStateMirrorTask?.cancel()
        voxmlxStateMirrorTask = nil
        mlxLMStateMirrorTask?.cancel()
        mlxLMStateMirrorTask = nil
        if voxmlxSupervisor != nil {
            setStatus(.stopped, for: BackendCatalog.voxmlx)
        }
        if mlxLMSupervisor != nil {
            setStatus(.stopped, for: BackendCatalog.mlxLM)
        }
    }

    func stopDictation() async {
        await voxmlxSupervisor?.stop()
        voxmlxStateMirrorTask?.cancel()
        voxmlxStateMirrorTask = nil
        if voxmlxSupervisor != nil {
            setStatus(.stopped, for: BackendCatalog.voxmlx)
        }
    }

    func stopPolishing() async {
        // Stop only the polishing supervisor. voxmlx (dictation) keeps running
        // and its state mirror is left intact. Modeled on stopAll()'s mlx-lm
        // branch: cancel the mirror task and pin the status to .stopped.
        await mlxLMSupervisor?.stop()
        mlxLMStateMirrorTask?.cancel()
        mlxLMStateMirrorTask = nil
        if mlxLMSupervisor != nil {
            setStatus(.stopped, for: BackendCatalog.mlxLM)
        }
    }

    func status(for spec: ManagedBackendSpec) -> ManagedBackendStatus {
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            return voxmlxStatus
        case BackendCatalog.mlxLM.id:
            return mlxLMStatus
        default:
            return .failed(summary: "Unknown managed backend '\(spec.id)'.", detail: nil)
        }
    }

    func recentOutput(for spec: ManagedBackendSpec) -> [String] {
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            return voxmlxSupervisor?.recentOutput ?? []
        case BackendCatalog.mlxLM.id:
            return mlxLMSupervisor?.recentOutput ?? []
        default:
            return []
        }
    }

    private func performEnsureReady(dictation: Bool, polishing: Bool) async throws {
        if dictation {
            try await ensureReady(BackendCatalog.voxmlx)
        }
        if polishing {
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
                setStatus(.failed(summary: detail, detail: nil), for: spec)
                throw ManagedBackendManagerError.backendFailed(
                    name: spec.displayName,
                    summary: detail,
                    detail: nil
                )
            }
        }

        try await prepareModel(for: spec)

        setStatus(.starting, for: spec)
        let supervisor = supervisor(for: spec)
        try await startAndWaitUntilReady(supervisor, spec: spec)
    }

    private func prepareModel(for spec: ManagedBackendSpec) async throws {
        let request = modelPreparationRequest(for: spec)
        setStatus(
            .preparingModel(progress: ModelDownloadProgress(downloadedBytes: 0, totalBytes: nil)),
            for: spec
        )
        do {
            try await modelPreparer.prepare(request) { [weak self] progress in
                guard let self else { return }
                self.setStatus(.preparingModel(progress: progress), for: spec)
            }
        } catch is CancellationError {
            setStatus(.stopped, for: spec)
            throw CancellationError()
        } catch {
            let summary = error.localizedDescription.trimmed.isEmpty
                ? "Model download failed."
                : error.localizedDescription
            let detail = (error as? ModelDownloadError)?.technicalDetails
            setStatus(.failed(summary: summary, detail: detail), for: spec)
            throw ManagedBackendManagerError.backendFailed(
                name: spec.displayName,
                summary: summary,
                detail: detail
            )
        }
    }

    private func startAndWaitUntilReady(
        _ supervisor: any ManagedBackendSupervising,
        spec: ManagedBackendSpec
    ) async throws {
        let updates = supervisor.stateUpdates
        await supervisor.start()

        for await state in updates {
            switch state {
            case .launching, .waitingForReady, .restarting:
                mirrorSupervisorState(state, for: spec)
            case .running:
                mirrorSupervisorState(state, for: spec)
                return
            case .failed(let summary, let detail):
                mirrorSupervisorState(state, for: spec)
                throw ManagedBackendManagerError.backendFailed(
                    name: spec.displayName,
                    summary: summary,
                    detail: detail
                )
            case .stopped:
                let message = "\(spec.displayName) stopped before it became ready."
                setStatus(.failed(summary: message, detail: nil), for: spec)
                throw ManagedBackendManagerError.backendFailed(
                    name: spec.displayName,
                    summary: message,
                    detail: nil
                )
            case .idle:
                break
            }
        }

        let message = "\(spec.displayName) stopped reporting status before it became ready."
        setStatus(.failed(summary: message, detail: nil), for: spec)
        throw ManagedBackendManagerError.backendFailed(
            name: spec.displayName,
            summary: message,
            detail: nil
        )
    }

    private func supervisor(for spec: ManagedBackendSpec) -> any ManagedBackendSupervising {
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            if let voxmlxSupervisor {
                startStateMirrorIfNeeded(supervisor: voxmlxSupervisor, spec: spec)
                return voxmlxSupervisor
            }
            let supervisor = supervisorFactory(configuration(for: spec))
            voxmlxSupervisor = supervisor
            startStateMirrorIfNeeded(supervisor: supervisor, spec: spec)
            return supervisor
        case BackendCatalog.mlxLM.id:
            if let mlxLMSupervisor {
                startStateMirrorIfNeeded(supervisor: mlxLMSupervisor, spec: spec)
                return mlxLMSupervisor
            }
            let supervisor = supervisorFactory(configuration(for: spec))
            mlxLMSupervisor = supervisor
            startStateMirrorIfNeeded(supervisor: supervisor, spec: spec)
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
            readinessURL: URL(string: "http://127.0.0.1:\(spec.port)/health")!,
            readinessTimeout: readinessTimeout(for: spec)
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

    private func modelPreparationRequest(for spec: ManagedBackendSpec) -> ModelPreparationRequest {
        // Keep these include patterns in sync with:
        // - /home/dev/work/voxmlx/voxmlx/weights.py download_model
        // - /home/dev/work/mlx-lm/mlx_lm/utils.py _download
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            return ModelPreparationRequest(
                backendID: spec.id,
                displayName: spec.displayName,
                repoID: SettingsStore.RealtimeProvider.realtimeAPI.defaultModelName,
                includePatterns: [
                    "consolidated.safetensors",
                    "model*.safetensors",
                    "model.safetensors.index.json",
                    "params.json",
                    "config.json",
                    "tekken.json",
                ]
            )
        case BackendCatalog.mlxLM.id:
            return ModelPreparationRequest(
                backendID: spec.id,
                displayName: spec.displayName,
                repoID: SettingsStore.defaultLLMPolishingModel,
                includePatterns: [
                    "*.json",
                    "model*.safetensors",
                    "*.py",
                    "tokenizer.model",
                    "*.tiktoken",
                    "tiktoken.model",
                    "*.txt",
                    "*.jsonl",
                    "*.jinja",
                ]
            )
        default:
            preconditionFailure("Unknown managed backend '\(spec.id)'.")
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
        // Deliberately leave Hugging Face cache variables unset: managed
        // backends share the user's already-downloaded weights, while uninstall
        // only owns the app-managed backends/ tree documented in README.
        environment.merge(layout.environment) { _, new in new }
        return environment
    }

    private func readinessTimeout(for spec: ManagedBackendSpec) -> Duration {
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            // First run downloads the model inside the server before /health
            // responds; 600 s is too tight on slow links.
            return .seconds(1800)
        case BackendCatalog.mlxLM.id:
            // First run downloads the polishing model inside the server before
            // /health responds; 600 s is too tight on slow links.
            return .seconds(1800)
        default:
            return .seconds(600)
        }
    }

    private func isReady(_ spec: ManagedBackendSpec) -> Bool {
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            return voxmlxSupervisor?.state == .running
        case BackendCatalog.mlxLM.id:
            return mlxLMSupervisor?.state == .running
        default:
            return false
        }
    }

    private func startStateMirrorIfNeeded(
        supervisor: any ManagedBackendSupervising,
        spec: ManagedBackendSpec
    ) {
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            guard voxmlxStateMirrorTask == nil else { return }
            voxmlxStateMirrorTask = makeStateMirrorTask(supervisor: supervisor, spec: spec)
        case BackendCatalog.mlxLM.id:
            guard mlxLMStateMirrorTask == nil else { return }
            mlxLMStateMirrorTask = makeStateMirrorTask(supervisor: supervisor, spec: spec)
        default:
            break
        }
    }

    private func makeStateMirrorTask(
        supervisor: any ManagedBackendSupervising,
        spec: ManagedBackendSpec
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self, supervisor, spec] in
            for await state in supervisor.stateUpdates {
                guard let self, !Task.isCancelled else { return }
                self.mirrorSupervisorState(state, for: spec)
            }
        }
    }

    private func mirrorSupervisorState(
        _ state: BackendProcessSupervisor.State,
        for spec: ManagedBackendSpec
    ) {
        switch state {
        case .idle:
            break
        case .launching, .waitingForReady, .restarting:
            setStatus(.starting, for: spec)
        case .running:
            setStatus(.ready, for: spec)
        case .failed(let summary, let detail):
            setStatus(.failed(summary: summary, detail: detail), for: spec)
        case .stopped:
            setStatus(.stopped, for: spec)
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
        let update = ManagedBackendStatusUpdate(spec: spec, status: status)
        for continuation in statusUpdateContinuations.values {
            continuation.yield(update)
        }
    }
}
