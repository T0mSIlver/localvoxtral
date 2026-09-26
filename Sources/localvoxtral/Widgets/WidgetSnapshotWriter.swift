import Foundation
import Observation
import WidgetKit
import notify

/// Writes the desktop widgets' snapshot and asks WidgetKit to reload them
/// (#630). It writes when an engine changes state, after a commit, when a
/// term is learned or a setting the widgets show changes, and never more
/// often than every few seconds: macOS limits how often a widget refreshes.
@MainActor
final class WidgetSnapshotWriter {
    private let viewModel: DictationViewModel
    private let fileURL: URL
    private let reloadTimelines: @MainActor () -> Void
    private let sleep: @Sendable (Duration) async -> Void
    private var pending: Task<Void, Never>?
    private var memoryRefresh: Task<Void, Never>?
    private var lastWritten: WidgetSnapshot?
    /// Set once the quit snapshot is written: a write still in flight must
    /// not replace it with running engines.
    private var hasQuit = false
    private var turnOffPolishToken: Int32 = NOTIFY_TOKEN_INVALID

    /// Between two writes; a model download's progress waits longer.
    static let coalesceInterval: Duration = .seconds(2)
    static let downloadInterval: Duration = .seconds(20)
    /// A helper's memory grows as its model loads and caches; nothing else
    /// would rewrite the snapshot while the Mac sits idle.
    static let memoryRefreshInterval: Duration = .seconds(600)

    init(
        viewModel: DictationViewModel,
        fileURL: URL = WidgetShared.fileURL(home: FileManager.default.homeDirectoryForCurrentUser),
        reloadTimelines: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.viewModel = viewModel
        self.fileURL = fileURL
        self.reloadTimelines = reloadTimelines
        self.sleep = sleep
    }

    func start() {
        observe()
        listenForTurnOffPolish()
        scheduleWrite(after: .zero)
        memoryRefresh = Task { [weak self, sleep] in
            while !Task.isCancelled {
                await sleep(Self.memoryRefreshInterval)
                guard let self, !Task.isCancelled else { return }
                self.scheduleWrite(after: .zero)
            }
        }
    }

    /// The app is quitting and its helpers with it: the widgets say so and
    /// drop the button. Synchronous, because termination cannot wait.
    func writeAppQuit() {
        hasQuit = true
        pending?.cancel()
        memoryRefresh?.cancel()
        if turnOffPolishToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(turnOffPolishToken)
            turnOffPolishToken = NOTIFY_TOKEN_INVALID
        }
        guard var snapshot = lastWritten else { return }
        snapshot.writtenAt = Date()
        snapshot.engines.appRunning = false
        for role in WidgetSnapshot.EngineRole.allCases {
            var engine = snapshot.engines.engine(role)
            if engine.mode == .managedLocal {
                engine.state = .idle
                engine.memoryBytes = nil
            }
            if role == .speech { snapshot.engines.speech = engine } else { snapshot.engines.polish = engine }
        }
        persist(snapshot)
    }

    // MARK: Triggers

    /// Everything the snapshot shows that the app can observe. Reading it
    /// under `withObservationTracking` is what registers the triggers.
    private func readTrackedState() {
        let settings = viewModel.settings
        _ = settings.dictationBackendMode
        _ = settings.polishingBackendMode
        _ = settings.llmPolishingEnabled
        _ = settings.managedSpeechModel
        _ = settings.managedLLMPolishingModel
        _ = settings.dictationHistoryRetention
        _ = viewModel.engines.backendManager.speechdStatus
        _ = viewModel.engines.backendManager.polishdStatus
        _ = viewModel.dictationHistoryRevision
        _ = viewModel.learnedTermRevision
        _ = viewModel.engines.mistralUsageRevision
    }

    private func observe() {
        withObservationTracking {
            readTrackedState()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe()
                self.scheduleWrite(after: self.isDownloading ? Self.downloadInterval : Self.coalesceInterval)
            }
        }
    }

    private var isDownloading: Bool {
        let manager = viewModel.engines.backendManager
        return [manager.speechdStatus, manager.polishdStatus].contains {
            if case .preparingModel = $0 { return true }
            return false
        }
    }

    /// Coalesces: a write already waiting picks up whatever changed since.
    private func scheduleWrite(after delay: Duration) {
        guard pending == nil else { return }
        pending = Task { [weak self, sleep] in
            await sleep(delay)
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            await self.write()
        }
    }

    private func listenForTurnOffPolish() {
        let status = notify_register_dispatch(
            WidgetShared.turnOffPolishNotification, &turnOffPolishToken, DispatchQueue.main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.viewModel.settings.llmPolishingEnabled else {
                    Log.widgets.notice("widget asked to turn polish off; it is already off")
                    return
                }
                Log.widgets.notice("widget turned polish off")
                self.viewModel.setLLMPolishingEnabled(false)
            }
        }
        if status != NOTIFY_STATUS_OK {
            Log.widgets.error("could not listen for the widget's Turn off polish (notify status \(status, privacy: .public))")
        }
    }

    // MARK: Writing

    func write() async {
        let now = Date()
        let calendar = Calendar.current
        let settings = viewModel.settings
        let historyKept = settings.dictationHistoryRetention.savesDictations

        var history = WidgetSnapshotAssembler.History(
            dictation: WidgetSnapshot.Dictation(), weeklyShares: [], lastDictation: nil, bundleIDs: [])
        if historyKept, let store = viewModel.sessionStore {
            let entries = await store.entries(since: WidgetSnapshotAssembler.historyStart(now: now))
            let terms = settings.polishSpeakerTerms
                + (viewModel.learnedTermStore?.snapshot().confirmedEverywhere().map(\.term) ?? [])
            // Weeks of word diffs: off the main actor.
            let counted = await Task.detached {
                WidgetSnapshotAssembler.history(entries: entries, terms: terms, now: now, calendar: calendar)
            }.value
            var names: [String: String] = [:]
            for id in counted.bundleIDs {
                names[id] = DictationHistoryModel.installedAppName(bundleID: id) ?? id
            }
            history = WidgetSnapshotAssembler.named(counted, names: names)
        }

        let learned = viewModel.learnedTermStore?.snapshot()
        let snapshot = WidgetSnapshot(
            writtenAt: now,
            engines: engines(now: now, calendar: calendar),
            dictation: history.dictation,
            vocabulary: WidgetSnapshot.Vocabulary(
                weeklyShares: history.weeklyShares,
                termCount: learned?.termCount ?? 0,
                termsLearnedThisWeek: learned.map { WidgetSnapshotAssembler.termsLearnedThisWeek($0, now: now) } ?? []
            ),
            historyKept: historyKept,
            lastDictation: history.lastDictation
        )
        guard !hasQuit else { return }
        persist(snapshot)
    }

    private func engines(now: Date, calendar: Calendar) -> WidgetSnapshot.Engines {
        let settings = viewModel.settings
        let manager = viewModel.engines.backendManager

        func engine(
            mode: BackendMode, status: ManagedBackendStatus, spec: ManagedBackendSpec, displayName: String
        ) -> WidgetSnapshot.Engine {
            guard mode == .managedLocal else {
                return WidgetSnapshot.Engine(mode: WidgetSnapshotAssembler.engineMode(mode), state: .ready)
            }
            let state = WidgetSnapshotAssembler.engineState(status)
            let running = state == .ready || state == .starting
            return WidgetSnapshot.Engine(
                mode: .managedLocal,
                shortModelName: WidgetModelName.short(displayName),
                modelName: WidgetModelName.full(displayName),
                state: state,
                memoryBytes: running ? manager.processID(for: spec).flatMap(ProcessMemory.footprint).map(Self.rounded) : nil
            )
        }

        let polishRepo = settings.resolvedManagedLLMPolishingModel
        return WidgetSnapshot.Engines(
            speech: engine(
                mode: settings.dictationBackendMode, status: manager.speechdStatus, spec: BackendCatalog.speechd,
                displayName: settings.resolvedManagedSpeechModel.displayName),
            polish: engine(
                mode: settings.polishingBackendMode, status: manager.polishdStatus, spec: BackendCatalog.polishd,
                displayName: PolishModelCatalog.option(forRepoID: polishRepo)?.displayName ?? polishRepo),
            polishEnabled: settings.llmPolishingEnabled,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            mistral: WidgetSnapshotAssembler.mistralSpend(
                viewModel.engines.mistralUsageLedger?.entries() ?? [], now: now, calendar: calendar)
        )
    }

    /// To the 100 MB the widget's one decimal shows, so a helper's memory
    /// drifting by a few pages does not rewrite the file.
    private static func rounded(_ bytes: UInt64) -> UInt64 {
        let step: UInt64 = 104_857_600
        return (bytes + step / 2) / step * step
    }

    private func persist(_ snapshot: WidgetSnapshot) {
        var unchanged = lastWritten
        unchanged?.writtenAt = snapshot.writtenAt
        guard unchanged != snapshot else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
            lastWritten = snapshot
            reloadTimelines()
            Log.widgets.info("wrote the widget snapshot and reloaded the widgets")
        } catch {
            Log.widgets.error("could not write the widget snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }
}
