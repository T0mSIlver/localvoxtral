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
    var polishdStatus: ManagedBackendStatus { get }
    var statusUpdates: AsyncStream<ManagedBackendStatusUpdate> { get }

    func ensureReady(dictation: Bool, polishing: Bool) async throws
    func stopAll() async
    /// Stop only the managed voxmlx (dictation) process, leaving polishd
    /// (polishing) untouched. A no-op if voxmlx was never started.
    func stopDictation() async
    /// Stop only the managed polishd (polishing) process, leaving voxmlx
    /// (dictation) untouched. A no-op if polishd was never started.
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
    typealias PolishingModelProvider = @MainActor () -> String

    private(set) var voxmlxStatus: ManagedBackendStatus
    private(set) var polishdStatus: ManagedBackendStatus

    @ObservationIgnored private let installer: any BackendInstalling
    @ObservationIgnored private let modelPreparer: any ModelPreparing
    @ObservationIgnored private let layout: BackendInstallLayout
    @ObservationIgnored private let supervisorFactory: SupervisorFactory
    @ObservationIgnored private let polishingModelProvider: PolishingModelProvider
    @ObservationIgnored private var voxmlxSupervisor: (any ManagedBackendSupervising)?
    @ObservationIgnored private var polishdSupervisor: (any ManagedBackendSupervising)?
    // Per-backend single-flight slots. A global shared slot (the previous
    // design) let a lingering dictation run swallow a polishing request whose
    // flags it never covered — field-hit 2026-07-04: enabling polishing did
    // nothing while an old ensure task lingered. Disjoint backends must never
    // share a slot.
    @ObservationIgnored private var dictationEnsureTask: Task<Void, Error>?
    @ObservationIgnored private var polishingEnsureTask: Task<Void, Error>?
    @ObservationIgnored private var voxmlxStateMirrorTask: Task<Void, Never>?
    @ObservationIgnored private var polishdStateMirrorTask: Task<Void, Never>?
    @ObservationIgnored private var statusUpdateContinuations: [UUID: AsyncStream<ManagedBackendStatusUpdate>.Continuation] = [:]
    #if DEBUG
    @ObservationIgnored var debugStatusChangeSink: ((ManagedBackendSpec, ManagedBackendStatus) -> Void)?
    #endif

    init(
        installer: any BackendInstalling = BackendInstaller(),
        modelPreparer: (any ModelPreparing)? = nil,
        layout: BackendInstallLayout = BackendInstallLayout(),
        polishingModelProvider: @escaping PolishingModelProvider = {
            SettingsStore.defaultLLMPolishingModel
        },
        supervisorFactory: @escaping SupervisorFactory = { configuration in
            BackendProcessSupervisor(configuration: configuration)
        }
    ) {
        self.installer = installer
        self.layout = layout
        self.modelPreparer = modelPreparer ?? HFModelDownloader(layout: layout)
        self.polishingModelProvider = polishingModelProvider
        self.supervisorFactory = supervisorFactory
        self.voxmlxStatus = installer.needsInstallOrUpdate(BackendCatalog.voxmlx)
            ? .notInstalled
            : .stopped
        self.polishdStatus = installer.needsInstallOrUpdate(BackendCatalog.polishd)
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
        Log.backends.info(
            "ensureReady requested dictation=\(dictation, privacy: .public) polishing=\(polishing, privacy: .public)"
        )
        var tasks: [Task<Void, Error>] = []
        if dictation {
            tasks.append(singleFlightEnsureTask(for: BackendCatalog.voxmlx))
        }
        if polishing {
            tasks.append(singleFlightEnsureTask(for: BackendCatalog.polishd))
        }
        for task in tasks {
            try await awaitEnsureReadyTask(task)
        }
    }

    /// Returns the in-flight ensure task for the backend, or starts one. Each
    /// backend has its own slot so concurrent callers join per-backend work
    /// and requests for different backends never block or swallow each other.
    private func singleFlightEnsureTask(for spec: ManagedBackendSpec) -> Task<Void, Error> {
        if spec.id == BackendCatalog.voxmlx.id, let dictationEnsureTask {
            return dictationEnsureTask
        }
        if spec.id == BackendCatalog.polishd.id, let polishingEnsureTask {
            return polishingEnsureTask
        }
        let task = Task { @MainActor in
            defer { self.clearEnsureTask(for: spec) }
            do {
                try await self.ensureReady(spec)
                Log.backends.info("\(spec.displayName, privacy: .public) ensure finished ready")
            } catch is CancellationError {
                Log.backends.info("\(spec.displayName, privacy: .public) ensure cancelled")
                throw CancellationError()
            } catch {
                Log.backends.error(
                    "\(spec.displayName, privacy: .public) ensure failed: \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
        }
        if spec.id == BackendCatalog.voxmlx.id {
            dictationEnsureTask = task
        } else {
            polishingEnsureTask = task
        }
        return task
    }

    private func clearEnsureTask(for spec: ManagedBackendSpec) {
        if spec.id == BackendCatalog.voxmlx.id {
            dictationEnsureTask = nil
        } else {
            polishingEnsureTask = nil
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
        let cancelledDictationEnsure = await cancelEnsureTaskAndAwaitCompletion(for: BackendCatalog.voxmlx)
        let cancelledPolishingEnsure = await cancelEnsureTaskAndAwaitCompletion(for: BackendCatalog.polishd)
        let hadPolishingSupervisor = polishdSupervisor != nil
        await voxmlxSupervisor?.stop()
        await polishdSupervisor?.stop()
        polishdSupervisor = nil
        voxmlxStateMirrorTask?.cancel()
        voxmlxStateMirrorTask = nil
        polishdStateMirrorTask?.cancel()
        polishdStateMirrorTask = nil
        if cancelledDictationEnsure || voxmlxSupervisor != nil {
            setStatus(.stopped, for: BackendCatalog.voxmlx)
        }
        if cancelledPolishingEnsure || hadPolishingSupervisor {
            setStatus(.stopped, for: BackendCatalog.polishd)
        }
    }

    func stopDictation() async {
        let cancelledEnsure = await cancelEnsureTaskAndAwaitCompletion(for: BackendCatalog.voxmlx)
        await voxmlxSupervisor?.stop()
        voxmlxStateMirrorTask?.cancel()
        voxmlxStateMirrorTask = nil
        if cancelledEnsure || voxmlxSupervisor != nil {
            setStatus(.stopped, for: BackendCatalog.voxmlx)
        }
    }

    func stopPolishing() async {
        // Stop only the polishing supervisor. voxmlx (dictation) keeps running
        // and its state mirror is left intact. Modeled on stopAll()'s polishd
        // branch: cancel the mirror task and pin the status to .stopped.
        let cancelledEnsure = await cancelEnsureTaskAndAwaitCompletion(for: BackendCatalog.polishd)
        let hadSupervisor = polishdSupervisor != nil
        await polishdSupervisor?.stop()
        polishdSupervisor = nil
        polishdStateMirrorTask?.cancel()
        polishdStateMirrorTask = nil
        if cancelledEnsure || hadSupervisor {
            setStatus(.stopped, for: BackendCatalog.polishd)
        }
    }

    /// Cancels the in-flight ensure task AND waits for it to finish unwinding.
    /// Returning before it completes let a new ensure start while the old
    /// one's model-download process was still terminating — two downloaders
    /// writing the same HF cache blob corrupt the partial file and force a
    /// restart (field finding: inflated "6 GB / 3.3 GB" progress, PR #99).
    private func cancelEnsureTaskAndAwaitCompletion(for spec: ManagedBackendSpec) async -> Bool {
        let task: Task<Void, Error>?
        if spec.id == BackendCatalog.voxmlx.id {
            task = dictationEnsureTask
        } else {
            task = polishingEnsureTask
        }
        guard let task else { return false }
        task.cancel()
        _ = try? await task.value
        return true
    }

    func status(for spec: ManagedBackendSpec) -> ManagedBackendStatus {
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            return voxmlxStatus
        case BackendCatalog.polishd.id:
            return polishdStatus
        default:
            return .failed(summary: "Unknown managed backend '\(spec.id)'.", detail: nil)
        }
    }

    func recentOutput(for spec: ManagedBackendSpec) -> [String] {
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            return voxmlxSupervisor?.recentOutput ?? []
        case BackendCatalog.polishd.id:
            return polishdSupervisor?.recentOutput ?? []
        default:
            return []
        }
    }

    private func ensureReady(_ spec: ManagedBackendSpec) async throws {
        if isReady(spec) {
            setStatus(.ready, for: spec)
            return
        }

        // Structural, not just data-driven: a bundled backend must never enter
        // the uv install path regardless of what an installer claims (the real
        // installer preconditionFailures on bundled installs).
        if case .uvWheel = spec.installKind, installer.needsInstallOrUpdate(spec) {
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
            try Task.checkCancellation()
        }

        try await prepareModel(for: spec)
        try Task.checkCancellation()

        setStatus(.starting, for: spec)
        try Task.checkCancellation()
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
        case BackendCatalog.polishd.id:
            if let polishdSupervisor {
                startStateMirrorIfNeeded(supervisor: polishdSupervisor, spec: spec)
                return polishdSupervisor
            }
            let supervisor = supervisorFactory(configuration(for: spec))
            polishdSupervisor = supervisor
            startStateMirrorIfNeeded(supervisor: supervisor, spec: spec)
            return supervisor
        default:
            preconditionFailure("Unknown managed backend '\(spec.id)'.")
        }
    }

    private func configuration(for spec: ManagedBackendSpec) -> BackendProcessConfiguration {
        BackendProcessConfiguration(
            name: spec.displayName,
            executableURL: executableURL(for: spec),
            arguments: arguments(for: spec),
            environment: processEnvironment(),
            readinessURL: URL(string: "http://127.0.0.1:\(spec.port)/health")!,
            readinessTimeout: readinessTimeout(for: spec)
        )
    }

    private func executableURL(for spec: ManagedBackendSpec) -> URL {
        switch spec.installKind {
        case .uvWheel:
            return layout.toolBin.appendingPathComponent(spec.executableName)
        case .bundledExecutable:
            // Packaged app: Contents/MacOS next to the main binary (that is
            // where package_app.sh copies the helper). Integration tests
            // spawn the helper binary directly and never route through here.
            if let auxiliary = Bundle.main.url(forAuxiliaryExecutable: spec.executableName) {
                return auxiliary
            }
            // Dev runs outside a packaged bundle: sibling of the main binary.
            // (`swift run` has no bundled helper — managed polishing fails at
            // spawn with a visible supervisor error there; use a packaged
            // build for hand-testing polishing.)
            return (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
                .deletingLastPathComponent()
                .appendingPathComponent(spec.executableName)
        }
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
        case BackendCatalog.polishd.id:
            return [
                "--model",
                polishingModelProvider(),
                "--port",
                "\(spec.port)",
                "--parent-pid",
                parentPID,
            ]
        default:
            return []
        }
    }

    private func modelPreparationRequest(for spec: ManagedBackendSpec) -> ModelPreparationRequest {
        // Keep these include patterns in sync with:
        // - /home/dev/work/voxmlx/voxmlx/weights.py download_model
        // - PolishHelper's loader (MLXLLM loadContainer + AutoTokenizer):
        //   config.json, generation_config.json, model*.safetensors,
        //   tokenizer.json/tokenizer_config.json, chat template *.jinja —
        //   the list below is a superset kept identical to the old mlx-lm
        //   one so existing HF snapshots stay valid.
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
        case BackendCatalog.polishd.id:
            return ModelPreparationRequest(
                backendID: spec.id,
                displayName: spec.displayName,
                repoID: polishingModelProvider(),
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
        case BackendCatalog.polishd.id:
            // Model weights are downloaded by prepareModel before the helper
            // spawns; /health waits only on model load + first Metal JIT
            // compile (seconds, not minutes).
            return .seconds(300)
        default:
            return .seconds(600)
        }
    }

    private func isReady(_ spec: ManagedBackendSpec) -> Bool {
        switch spec.id {
        case BackendCatalog.voxmlx.id:
            return voxmlxSupervisor?.state == .running
        case BackendCatalog.polishd.id:
            return polishdSupervisor?.state == .running
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
        case BackendCatalog.polishd.id:
            guard polishdStateMirrorTask == nil else { return }
            polishdStateMirrorTask = makeStateMirrorTask(supervisor: supervisor, spec: spec)
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
        case BackendCatalog.polishd.id:
            polishdStatus = status
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
