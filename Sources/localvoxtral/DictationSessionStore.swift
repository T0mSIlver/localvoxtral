import Foundation
import os
import SwiftData

/// One saved dictation as a value. `DictationSessionRecord` is a SwiftData
/// model bound to the context that fetched it, so nothing outside the store
/// ever holds one: reads come back as these.
struct DictationHistoryEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let finishedAt: Date
    let rawText: String
    let polishedText: String?
    let polishingDurationSeconds: Double?
    let provider: String
    let model: String
    let outputMode: String
    let targetAppBundleID: String?
    let status: DictationSessionStatus
    let commitSucceeded: Bool
    let polishProfile: String?
    let polishContextSummary: String?
    var projectKey: String? = nil
    var projectName: String? = nil
    var joinedAgent: String? = nil
    /// Where a quick capture went; nil for every other dictation.
    var quickCaptureDestination: String? = nil
    /// `EditSignalOutcome`'s raw value, nil when nothing was watched.
    var editOutcome: String? = nil
    var polishPromptTokens: Int? = nil

    /// What the dictation ended up as, the transcript when nothing changed it.
    var finalText: String { polishedText ?? rawText }

    /// `polishedText` holds whatever the commit path turned the transcript
    /// into, and that is not always a model's work: with polishing off, the
    /// replacement dictionary and the clipboard marker land there too. The
    /// commit path stores it only when it differs, but a record written by an
    /// older build may hold an equal copy.
    var textWasChanged: Bool {
        guard let polishedText else { return false }
        return polishedText != rawText
    }

    /// A polish request answered for this dictation. Only the polish path
    /// records a duration.
    var polishRan: Bool { polishingDurationSeconds != nil && status != .llmFailed }

    /// This entry with `polishedText` replaced, for the in-memory copy that
    /// may hold what History must not (the clipboard payload).
    func replacingPolishedText(_ text: String?) -> DictationHistoryEntry {
        DictationHistoryEntry(
            id: id, startedAt: startedAt, finishedAt: finishedAt, rawText: rawText,
            polishedText: text, polishingDurationSeconds: polishingDurationSeconds,
            provider: provider, model: model, outputMode: outputMode,
            targetAppBundleID: targetAppBundleID, status: status,
            commitSucceeded: commitSucceeded, polishProfile: polishProfile,
            polishContextSummary: polishContextSummary, projectKey: projectKey,
            projectName: projectName, joinedAgent: joinedAgent,
            quickCaptureDestination: quickCaptureDestination, editOutcome: editOutcome,
            polishPromptTokens: polishPromptTokens)
    }

    /// What "Copy last dictation" copies, nil when there is no text.
    var textToCopy: String? {
        LastDictationCopy.text(
            rawText: rawText, polishedText: polishedText, polishFailed: status == .llmFailed)
    }
}

extension DictationHistoryEntry {
    init(_ record: DictationSessionRecord) {
        self.init(
            id: record.id,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt,
            rawText: record.rawText,
            polishedText: record.polishedText,
            polishingDurationSeconds: record.polishingDurationSeconds,
            provider: record.provider,
            model: record.model,
            outputMode: record.outputMode,
            targetAppBundleID: record.targetAppBundleID,
            status: DictationSessionStatus(rawValue: record.status) ?? .completed,
            commitSucceeded: record.commitSucceeded,
            polishProfile: record.polishProfile,
            polishContextSummary: record.polishContextSummary,
            projectKey: record.projectKey,
            projectName: record.projectName,
            joinedAgent: record.joinedAgent,
            quickCaptureDestination: record.quickCaptureDestination,
            editOutcome: record.editOutcome,
            polishPromptTokens: record.polishPromptTokens
        )
    }

    fileprivate func makeRecord() -> DictationSessionRecord {
        let record = DictationSessionRecord(
            id: id,
            startedAt: startedAt,
            finishedAt: finishedAt,
            rawText: rawText,
            polishedText: polishedText,
            polishingDurationSeconds: polishingDurationSeconds,
            provider: provider,
            model: model,
            outputMode: outputMode,
            targetAppBundleID: targetAppBundleID,
            status: status,
            commitSucceeded: commitSucceeded,
            polishProfile: polishProfile,
            polishContextSummary: polishContextSummary,
            projectKey: projectKey,
            projectName: projectName,
            joinedAgent: joinedAgent,
            quickCaptureDestination: quickCaptureDestination,
            editOutcome: editOutcome
        )
        record.polishPromptTokens = polishPromptTokens
        return record
    }
}

/// Which saved dictations a read wants.
struct DictationHistoryQuery: Equatable, Sendable {
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all
        /// The text never reached the target app, so the history is the only
        /// place it still exists.
        case notInserted
        case polishFailed

        var id: String { rawValue }
    }

    /// Matched against the transcript and the polished text, ignoring case and
    /// diacritics. Empty matches everything.
    var searchText = ""
    var filter = Filter.all
    /// Only dictations that started at or after this. Nil is all of them.
    var since: Date?
    var limit = 500
}

@MainActor
final class DictationSessionStore {
    private let modelContainer: ModelContainer
    /// Every write runs behind the one before it. Each operation uses its own
    /// `ModelContext`, and two contexts saving at once is how a delete-all
    /// would lose to the insert it was started after.
    private var lastWrite: Task<Void, Never>?
    /// Called after every write that changed something, so an open History
    /// pane reads again.
    var onChange: (@MainActor () -> Void)?
    /// Where each dictation's audio goes when the user keeps it. Set once, at
    /// launch; nil keeps no audio and deletes none.
    var audioStore: DictationAudioStore?
    /// Where each dictation's diagnostic record goes. Deleted with its
    /// dictation, like the audio; nil keeps none and deletes none.
    var diagnosticRecordStore: DiagnosticRecordStore?

    /// The last read or write that failed, in the words of its error; nil
    /// once one succeeds. History and Insights show it instead of an empty
    /// page (#985).
    private(set) var accessFailure: String?
    /// Called when `accessFailure` changes, so the popover and the panes
    /// can say History is failing while it fails.
    var onAccessFailureChange: (@MainActor (String?) -> Void)?

    /// Whether the last read or write failed. Retention and the sweeps
    /// wait while it does: a store that cannot answer is no authority for
    /// deleting anything (#985).
    var isFailing: Bool { accessFailure != nil }

    /// The user's history: `history.store` in `directory`, which defaults to
    /// the app's folder in Application Support. With the default folder, a
    /// `default.store` left by an older build is copied in first, once.
    static func open(directory: URL? = nil) -> Result<DictationSessionStore, DictationHistoryOpenFailure> {
        let folder = directory ?? DictationHistoryStoreFile.defaultDirectoryURL()
        let url = folder.appendingPathComponent(DictationHistoryStoreFile.fileName)
        // Core Data creates the file, not its folder: a first launch has none.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if directory == nil {
            let legacy = DictationHistoryStoreFile.legacyStoreURL()
            switch DictationHistoryStoreFile.importLegacyStore(from: legacy, to: url) {
            case .storeExists, .noLegacyStore:
                break
            case .imported:
                Log.persistence.info(
                    "History: copied \(legacy.path, privacy: .public) to \(url.path, privacy: .public); the old file stays"
                )
            case let .legacyHoldsNoHistory(tables):
                Log.persistence.error(
                    "History: \(legacy.path, privacy: .public) holds no dictations (entity tables: \(tables, privacy: .public)); starting \(url.path, privacy: .public) empty"
                )
            case let .failed(reason):
                Log.persistence.error(
                    "History: copying \(legacy.path, privacy: .public) failed: \(reason, privacy: .public)"
                )
                return .failure(.unreadable("copying the history from default.store failed: \(reason)"))
            }
        }
        return open(url: url)
    }

    /// A store file at `url`: the user's, or a copy for the replay eval.
    /// Refuses a file holding data this build's model lacks, before SwiftData
    /// could migrate it away.
    static func open(url: URL) -> Result<DictationSessionStore, DictationHistoryOpenFailure> {
        let schema = Schema([DictationSessionRecord.self])
        let result: Result<DictationSessionStore, DictationHistoryOpenFailure>
        do {
            let unknown = try DictationHistoryStoreFile.unknownContents(of: url, schema: schema)
            if !unknown.tables.isEmpty || !unknown.columns.isEmpty {
                result = .failure(.unknownContents(tables: unknown.tables, columns: unknown.columns))
            } else {
                result = .success(try DictationSessionStore(
                    configuration: ModelConfiguration(schema: schema, url: url)))
            }
        } catch {
            result = .failure(.unreadable(String(describing: error)))
        }
        switch result {
        case .success:
            Log.persistence.info("History: opened \(url.path, privacy: .public)")
        case let .failure(failure):
            Log.persistence.error(
                "History: not opening \(url.path, privacy: .public): \(failure.logDescription, privacy: .public)"
            )
        }
        return result
    }

    /// A store that lives in memory, for tests.
    static func inMemory() -> DictationSessionStore? {
        let schema = Schema([DictationSessionRecord.self])
        return try? DictationSessionStore(
            configuration: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private convenience init(configuration: ModelConfiguration) throws {
        let schema = Schema([DictationSessionRecord.self])
        self.init(container: try ModelContainer(for: schema, configurations: [configuration]))
    }

    private init(container: ModelContainer) {
        modelContainer = container
    }

    // MARK: - Writes

    /// The returned task finishes once the record is on disk; production
    /// callers drop it.
    /// `audio` is the dictation's 16 kHz mono PCM16, written beside the
    /// record in the same step, so no trim can run between the two. The
    /// record is saved first: a save that fails leaves no file behind.
    @discardableResult
    func save(_ record: DictationSessionRecord, audio: Data? = nil) -> Task<Void, Never> {
        let entry = DictationHistoryEntry(record)
        let audioStore = audio == nil ? nil : audioStore
        return enqueueWrite("save dictation \(entry.id)") { context in
            context.insert(entry.makeRecord())
            try context.save()
            if let audio, let audioStore {
                do {
                    try audioStore.write(pcm16: audio, for: entry.id)
                    Log.persistence.info(
                        "History: saved \(audio.count / AudioChunkBuffer.bytesPerSecond, privacy: .public) s of audio for dictation \(entry.id, privacy: .public)"
                    )
                } catch {
                    Log.persistence.error(
                        "History: audio write failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return 1
        }
    }

    /// Marks where a quick capture went (#725). A record History no longer
    /// holds changes nothing.
    @discardableResult
    func setQuickCaptureDestination(_ destination: String, id: UUID) -> Task<Void, Never> {
        enqueueWrite("mark quick capture \(id)") { context in
            let records = try context.fetch(
                FetchDescriptor<DictationSessionRecord>(
                    predicate: #Predicate<DictationSessionRecord> { $0.id == id }))
            for record in records { record.quickCaptureDestination = destination }
            return records.count
        }
    }

    @discardableResult
    func delete(id: UUID) -> Task<Void, Never> {
        let audioStore = audioStore
        let diagnosticRecordStore = diagnosticRecordStore
        // The record goes first: a save that fails keeps the dictation with its
        // audio, and a file that will not go is retried by the next sweep.
        return enqueueWrite("delete dictation \(id)") { context in
            let deleted = try Self.deleteRecords(
                matching: #Predicate<DictationSessionRecord> { $0.id == id }, in: context)
            try context.save()
            audioStore?.remove([id])
            diagnosticRecordStore?.remove([id])
            return deleted.count
        }
    }

    @discardableResult
    func deleteAll() -> Task<Void, Never> {
        let audioStore = audioStore
        let diagnosticRecordStore = diagnosticRecordStore
        return enqueueWrite("delete all dictations") { context in
            let deleted = try Self.deleteRecords(matching: nil, in: context)
            try context.save()
            audioStore?.removeAll()
            diagnosticRecordStore?.removeAll()
            return deleted.count
        }
    }

    /// Deletes every dictation that started before `cutoff`
    /// (`DictationHistoryRetention.cutoff(now:)`), and the audio and
    /// diagnostic record of every dictation no longer in the store.
    @discardableResult
    func trim(olderThan cutoff: Date) -> Task<Void, Never> {
        let audioStore = audioStore
        let diagnosticRecordStore = diagnosticRecordStore
        guard !isFailing else { return skipWhileFailing("trim dictations") }
        return enqueueWrite("trim dictations") { context in
            let deleted = try Self.deleteRecords(
                matching: #Predicate<DictationSessionRecord> { $0.startedAt < cutoff },
                in: context)
            if !deleted.isEmpty, audioStore != nil || diagnosticRecordStore != nil {
                try context.save()
                // By id: a trim that empties the store leaves the sweep
                // below nothing to go on.
                audioStore?.remove(Set(deleted))
                diagnosticRecordStore?.remove(Set(deleted))
            }
            if let audioStore {
                try Self.removeOrphanedAudio(audioStore, context: context)
            }
            if let diagnosticRecordStore {
                try Self.removeOrphanedDiagnosticRecords(diagnosticRecordStore, context: context)
            }
            return deleted.count
        }
    }

    /// Deletes the recordings and diagnostic records whose dictation is
    /// gone, and records past their own limit. Run at launch, where Forever
    /// retention never trims: it is what retries a delete that failed and
    /// clears a file a crash left behind.
    @discardableResult
    func removeOrphanedAudio() -> Task<Void, Never> {
        let audioStore = audioStore
        let diagnosticRecordStore = diagnosticRecordStore
        guard !isFailing else { return skipWhileFailing("sweep dictation audio") }
        return enqueueWrite("sweep dictation audio") { context in
            // Before anything is deleted, strays and pruning included: an
            // empty store beside files lost its rows.
            let files = (audioStore?.storedIDs().count ?? 0)
                + (diagnosticRecordStore?.storedIDs().count ?? 0)
            if files > 0, try !Self.storeHoldsDictations(context, files: files, kind: "attachment") {
                return 0
            }
            if let audioStore {
                audioStore.removeStrayFiles()
                try Self.removeOrphanedAudio(audioStore, context: context)
            }
            if let diagnosticRecordStore {
                diagnosticRecordStore.removeStrayFiles()
                diagnosticRecordStore.prune()
                try Self.removeOrphanedDiagnosticRecords(diagnosticRecordStore, context: context)
            }
            return 0
        }
    }

    private nonisolated static func removeOrphanedDiagnosticRecords(
        _ diagnosticRecordStore: DiagnosticRecordStore, context: ModelContext
    ) throws {
        let stored = Array(diagnosticRecordStore.storedIDs())
        guard !stored.isEmpty,
              try storeHoldsDictations(context, files: stored.count, kind: "diagnostic record")
        else { return }
        let kept = try Set(context.fetch(FetchDescriptor<DictationSessionRecord>(
            predicate: #Predicate { stored.contains($0.id) })).map(\.id))
        let removed = diagnosticRecordStore.removeAll(except: kept)
        if removed > 0 {
            Log.persistence.info(
                "History: deleted \(removed, privacy: .public) diagnostic record(s) whose dictation is gone"
            )
        }
    }

    /// An empty store beside files is a store that lost its rows, not a user
    /// who deleted every dictation: Delete All removes the files itself. The
    /// sweep that trusted it deleted every recording after the #985 wipe.
    private nonisolated static func storeHoldsDictations(
        _ context: ModelContext, files: Int, kind: String
    ) throws -> Bool {
        guard try context.fetchCount(FetchDescriptor<DictationSessionRecord>()) == 0 else {
            return true
        }
        Log.persistence.error(
            "History: the store holds no dictations but \(files, privacy: .public) \(kind, privacy: .public) file(s) exist; keeping them"
        )
        return false
    }

    /// Only the recordings on disk are looked up: most users keep none, and
    /// this runs after every saved dictation.
    private nonisolated static func removeOrphanedAudio(
        _ audioStore: DictationAudioStore, context: ModelContext
    ) throws {
        let stored = Array(audioStore.storedIDs())
        guard !stored.isEmpty,
              try storeHoldsDictations(context, files: stored.count, kind: "recording")
        else { return }
        let kept = try Set(context.fetch(FetchDescriptor<DictationSessionRecord>(
            predicate: #Predicate { stored.contains($0.id) })).map(\.id))
        let removed = audioStore.removeAll(except: kept)
        if removed > 0 {
            Log.persistence.info(
                "History: deleted \(removed, privacy: .public) recording(s) whose dictation is gone"
            )
        }
    }

    /// Deletes every recording and keeps the dictations: the audio setting
    /// turned off.
    @discardableResult
    func deleteAllAudio() -> Task<Void, Never> {
        let audioStore = audioStore
        return enqueueWrite("delete all dictation audio") { _ in
            let removed = audioStore?.removeAll() ?? 0
            Log.persistence.info("History: deleted \(removed, privacy: .public) recording(s)")
            return 0
        }
    }

    /// Runs `write` (a diagnostic record's) behind every History write queued
    /// before it, and only while dictation `id` is still saved: a Delete, a
    /// trim or Don't keep queued earlier wins, and one queued later deletes
    /// the record it wrote.
    func writeDiagnosticRecord(
        forDictation id: UUID,
        _ write: @escaping @Sendable () -> URL?
    ) async -> URL? {
        let container = modelContainer
        let previous = lastWrite
        let task = Task.detached { () -> URL? in
            await previous?.value
            let context = ModelContext(container)
            let saved = (try? context.fetchCount(FetchDescriptor<DictationSessionRecord>(
                predicate: #Predicate { $0.id == id }))) ?? 0
            guard saved > 0 else {
                Log.persistence.info(
                    "History: no diagnostic record for dictation \(id, privacy: .public), which is no longer saved"
                )
                return nil
            }
            return write()
        }
        lastWrite = Task { _ = await task.value }
        return await task.value
    }

    /// Copies the edit watch's verdict onto the dictation, for Insights.
    @discardableResult
    func setEditOutcome(_ outcome: EditSignalOutcome, forDictation id: UUID) -> Task<Void, Never> {
        let value = outcome.rawValue
        return enqueueWrite("record the edit outcome of dictation \(id)") { context in
            let records = try context.fetch(FetchDescriptor<DictationSessionRecord>(
                predicate: #Predicate { $0.id == id }))
            for record in records { record.editOutcome = value }
            return records.count
        }
    }

    /// Deletes every diagnostic record and keeps the dictations: the
    /// diagnostic records setting turned off.
    @discardableResult
    func deleteAllDiagnosticRecords() -> Task<Void, Never> {
        let diagnosticRecordStore = diagnosticRecordStore
        return enqueueWrite("delete all diagnostic records") { _ in
            let removed = diagnosticRecordStore?.removeAll() ?? 0
            Log.persistence.info("History: deleted \(removed, privacy: .public) diagnostic record(s)")
            return 0
        }
    }

    /// Fetch-then-delete rather than `ModelContext.delete(model:where:)`: the
    /// batch form bypasses the context, and these sets are small.
    private nonisolated static func deleteRecords(
        matching predicate: Predicate<DictationSessionRecord>?,
        in context: ModelContext
    ) throws -> [UUID] {
        let records = try context.fetch(FetchDescriptor<DictationSessionRecord>(predicate: predicate))
        let ids = records.map(\.id)
        for record in records { context.delete(record) }
        return ids
    }

    private func enqueueWrite(
        _ label: String,
        _ body: @escaping @Sendable (ModelContext) throws -> Int
    ) -> Task<Void, Never> {
        let container = modelContainer
        let previous = lastWrite
        let task = Task.detached { [weak self] in
            await previous?.value
            var changed = 0
            do {
                let context = ModelContext(container)
                changed = try body(context)
                if changed > 0 { try context.save() }
                Log.persistence.info(
                    "History: \(label, privacy: .public) changed \(changed, privacy: .public) record(s)"
                )
                await self?.noteAccess(failure: nil)
            } catch {
                changed = 0
                Log.persistence.error(
                    "History: \(label, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
                await self?.noteAccess(failure: error.localizedDescription)
            }
            if changed > 0 {
                await self?.onChange?()
            }
        }
        lastWrite = task
        return task
    }

    // MARK: - Reads

    /// Newest first. Waits for the writes already queued, so a read that
    /// follows a delete never shows the deleted row.
    func entries(matching query: DictationHistoryQuery = DictationHistoryQuery()) async
        -> [DictationHistoryEntry]
    {
        await read("fetch dictations") { context in
            let search = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchAnyText = search.isEmpty
            let notInsertedOnly = query.filter == .notInserted
            let polishFailedOnly = query.filter == .polishFailed
            let polishFailed = DictationSessionStatus.llmFailed.rawValue
            let since = query.since ?? .distantPast
            var descriptor = FetchDescriptor<DictationSessionRecord>(
                predicate: #Predicate { record in
                    (matchAnyText
                        || record.rawText.localizedStandardContains(search)
                        || (record.polishedText?.localizedStandardContains(search) == true))
                        && (!notInsertedOnly || !record.commitSucceeded)
                        && (!polishFailedOnly || record.status == polishFailed)
                        && record.startedAt >= since
                },
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
            descriptor.fetchLimit = query.limit
            return try context.fetch(descriptor).map(DictationHistoryEntry.init)
        } ?? []
    }

    /// Every dictation that started at or after `since` (all of them for nil),
    /// for the insights, which count rather than list.
    func entries(since: Date?) async -> [DictationHistoryEntry] {
        await read("fetch dictations for insights") { context in
            let from = since ?? .distantPast
            let descriptor = FetchDescriptor<DictationSessionRecord>(
                predicate: #Predicate { $0.startedAt >= from },
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
            return try context.fetch(descriptor).map(DictationHistoryEntry.init)
        } ?? []
    }

    /// Recordings on disk and their size, for the Settings row.
    func diagnosticRecordSummary() async -> (records: Int, bytes: Int) {
        guard let diagnosticRecordStore else { return (0, 0) }
        return await read("summarize diagnostic records") { _ in
            diagnosticRecordStore.summary()
        } ?? (0, 0)
    }


    func audioSummary() async -> (recordings: Int, bytes: Int) {
        guard let audioStore else { return (0, 0) }
        return await read("summarize dictation audio") { _ in
            (audioStore.storedIDs().count, audioStore.totalBytes())
        } ?? (0, 0)
    }

    func count() async -> Int {
        await read("count dictations") { context in
            try context.fetchCount(FetchDescriptor<DictationSessionRecord>())
        } ?? 0
    }

    /// How many dictations `trim(olderThan:)` would delete, for the question
    /// the History pane asks before shortening the retention. Nil when the
    /// store could not say: a failed count is not "nothing to delete".
    func count(olderThan cutoff: Date) async -> Int? {
        await read("count dictations before a cutoff") { context in
            try context.fetchCount(
                FetchDescriptor<DictationSessionRecord>(
                    predicate: #Predicate { $0.startedAt < cutoff }))
        }
    }

    /// The text each recent dictation ended up as (polished when there was a
    /// polish, raw otherwise), newest first.
    func recentEntries(limit: Int) async -> [DictationHistoryEntry] {
        var query = DictationHistoryQuery()
        query.limit = limit
        return await entries(matching: query)
    }

    private func read<Value: Sendable>(
        _ label: String,
        _ body: @escaping @Sendable (ModelContext) throws -> Value
    ) async -> Value? {
        let container = modelContainer
        let pendingWrite = lastWrite
        let result = await Task.detached { () -> Result<Value, any Error> in
            await pendingWrite?.value
            return Result { try body(ModelContext(container)) }
        }.value
        switch result {
        case let .success(value):
            noteAccess(failure: nil)
            return value
        case let .failure(error):
            Log.persistence.error(
                "History: \(label, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
            noteAccess(failure: error.localizedDescription)
            return nil
        }
    }

    private func noteAccess(failure: String?) {
        guard accessFailure != failure else { return }
        accessFailure = failure
        onAccessFailureChange?(failure)
    }

    private func skipWhileFailing(_ label: String) -> Task<Void, Never> {
        Log.persistence.error(
            "History: skipping \(label, privacy: .public): the store's last read or write failed"
        )
        return Task {}
    }

    /// The queued writes, for the quit path to wait on.
    var pendingWrites: Task<Void, Never>? { lastWrite }
}
