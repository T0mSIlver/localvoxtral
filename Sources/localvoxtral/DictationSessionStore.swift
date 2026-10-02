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
    /// Snapshots taken before a trim or a sweep deletes; nil takes none.
    var backups: DictationHistoryBackups?
    /// Where the sweeps move what they find; nil deletes it.
    var quarantine: DictationHistoryQuarantine?
    /// The store's file; nil in memory.
    private(set) var storeURL: URL?
    var now: @Sendable () -> Date = { Date() }

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

    /// What the one-time copy from `default.store` did at this launch; nil
    /// when it did not run.
    private(set) var legacyImport: DictationHistoryStoreFile.LegacyImport?

    /// The user's history: `history.store` in `directory`, which defaults to
    /// the app's folder in Application Support. A `default.store` left by an
    /// older build (`legacyStore`, the real one with the default folder) is
    /// copied in first, once. Snapshots go to `backups/history` in the same
    /// folder, and the sweeps move what they find to `quarantine`.
    static func open(
        directory: URL? = nil, legacyStore: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> Result<DictationSessionStore, DictationHistoryOpenFailure> {
        let folder = directory ?? DictationHistoryStoreFile.defaultDirectoryURL()
        let url = folder.appendingPathComponent(DictationHistoryStoreFile.fileName)
        // Core Data creates the file, not its folder: a first launch has none.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var legacyImport: DictationHistoryStoreFile.LegacyImport?
        if let legacy = legacyStore ?? (directory == nil ? DictationHistoryStoreFile.legacyStoreURL() : nil) {
            let outcome = DictationHistoryStoreFile.importLegacyStore(from: legacy, to: url)
            legacyImport = outcome
            switch outcome {
            case .storeExists, .noLegacyStore:
                break
            case .imported:
                Log.persistence.info(
                    "History: copied \(legacy.path, privacy: .public) to \(url.path, privacy: .public); the old file stays"
                )
            case let .legacyHoldsNoHistory(tables):
                Log.persistence.error(
                    "History: \(legacy.path, privacy: .public) holds no dictations (entity tables: \(tables, privacy: .public)); copied nothing and left it in place; starting \(url.path, privacy: .public) empty. Restore it by hand if a backup has them."
                )
            case let .failed(reason):
                Log.persistence.error(
                    "History: copying \(legacy.path, privacy: .public) failed: \(reason, privacy: .public)"
                )
                return .failure(.unreadable("copying the history from default.store failed: \(reason)"))
            }
        }
        let backups = DictationHistoryBackups(
            directoryURL: DictationHistoryBackups.directory(inHistoryFolder: folder), now: now)
        let result = open(url: url, backups: backups)
        if case let .success(store) = result {
            store.legacyImport = legacyImport
            backups.snapshotIfDue(of: url)
            store.backups = backups
            store.quarantine = DictationHistoryQuarantine(
                directoryURL: DictationHistoryQuarantine.directory(inHistoryFolder: folder), now: now)
            store.now = now
        }
        return result
    }

    /// A store file at `url`: the user's, or a copy for the replay eval.
    /// Refuses a file holding data this build's model lacks, before SwiftData
    /// could migrate it away.
    /// With `backups`, a file this build is about to migrate is copied first.
    static func open(
        url: URL, backups: DictationHistoryBackups? = nil
    ) -> Result<DictationSessionStore, DictationHistoryOpenFailure> {
        let schema = Schema([DictationSessionRecord.self])
        let result: Result<DictationSessionStore, DictationHistoryOpenFailure>
        do {
            if let refusal = try DictationHistoryStoreFile.refusal(of: url, schema: schema) {
                result = .failure(refusal)
            } else {
                if let backups, try DictationHistoryStoreFile.needsUpgrade(url, schema: schema) {
                    backups.snapshot(of: url, reason: .migration)
                }
                let store = try DictationSessionStore(
                    configuration: ModelConfiguration(schema: schema, url: url))
                store.storeURL = url
                result = .success(store)
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
        let backups = backups
        let storeURL = storeURL
        return enqueueWrite("save dictation \(entry.id)") { context in
            context.insert(entry.makeRecord())
            try context.save()
            // The daily copy, for an app that runs for days: the one taken at
            // launch would be the last. On the write queue, after the save.
            if let backups, let storeURL { backups.snapshotIfDue(of: storeURL) }
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

    /// A quick capture's polished words (#970). The record was written with
    /// the raw words before the Inbox polished them.
    @discardableResult
    func setQuickCapturePolish(_ polishedText: String, seconds: Double, id: UUID) -> Task<Void, Never> {
        enqueueWrite("polish quick capture \(id)") { context in
            let records = try context.fetch(
                FetchDescriptor<DictationSessionRecord>(
                    predicate: #Predicate<DictationSessionRecord> { $0.id == id }))
            for record in records {
                record.polishedText = polishedText
                record.polishingDurationSeconds = seconds
            }
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
    /// (`DictationHistoryRetention.cutoff(now:)`) with its audio and
    /// diagnostic record, then sweeps the attachments whose dictation is gone.
    /// A snapshot of the store comes first when something will go.
    @discardableResult
    func trim(olderThan cutoff: Date) -> Task<Void, Never> {
        guard !isFailing else { return skipWhileFailing("trim dictations") }
        let attachments = attachments
        return enqueueWrite("trim dictations") { context in
            let expired = #Predicate<DictationSessionRecord> { $0.startedAt < cutoff }
            if try context.fetchCount(FetchDescriptor(predicate: expired)) > 0 {
                attachments.snapshotBeforeDelete()
            }
            let deleted = try Self.deleteRecords(matching: expired, in: context)
            if !deleted.isEmpty, attachments.audio != nil || attachments.diagnostics != nil {
                try context.save()
                // By id: the user's retention setting chose these, and a trim
                // that empties the store leaves the sweep nothing to go on.
                attachments.audio?.remove(deleted)
                attachments.diagnostics?.remove(deleted)
            }
            try attachments.sweepOrphans(context: context)
            return deleted.count
        }
    }

    /// Sweeps the recordings and diagnostic records whose dictation is gone,
    /// the files a crash left behind, and diagnostic records past their own
    /// limit. Run at launch, where Forever retention never trims: it is what
    /// retries a delete that failed.
    @discardableResult
    func removeOrphanedAudio() -> Task<Void, Never> {
        guard !isFailing else { return skipWhileFailing("sweep dictation audio") }
        let attachments = attachments
        let strayCutoff = now().addingTimeInterval(-Self.strayFileAge)
        return enqueueWrite("sweep dictation audio") { context in
            // Before anything is touched, strays and pruning included: an
            // empty store beside files lost its rows.
            let files = (attachments.audio?.storedIDs().count ?? 0)
                + (attachments.diagnostics?.storedIDs().count ?? 0)
            if files > 0, try !Self.storeHoldsDictations(context, files: files) {
                return 0
            }
            attachments.quarantine?.purge()
            attachments.moveStrayAudio(writtenBefore: strayCutoff)
            if let diagnostics = attachments.diagnostics {
                diagnostics.removeStrayFiles()
                diagnostics.prune()
            }
            try attachments.sweepOrphans(context: context)
            return 0
        }
    }

    /// A stray file younger than this may be another copy of the app
    /// writing it right now.
    static let strayFileAge: TimeInterval = 3_600
    /// More orphans than this in one sweep is not a failed delete or a
    /// crash; it is a store that lost rows. Nothing moves, and the log says so.
    nonisolated static let maximumOrphansPerSweep = 20

    /// An empty store beside files is a store that lost its rows, not a user
    /// who deleted every dictation: Delete All removes the files itself. The
    /// sweep that trusted it deleted every recording after the #985 wipe.
    fileprivate nonisolated static func storeHoldsDictations(
        _ context: ModelContext, files: Int
    ) throws -> Bool {
        guard try context.fetchCount(FetchDescriptor<DictationSessionRecord>()) == 0 else {
            return true
        }
        Log.persistence.error(
            "History: the store holds no dictations but \(files, privacy: .public) attachment file(s) exist; keeping them"
        )
        return false
    }

    private var attachments: SweptAttachments {
        SweptAttachments(
            audio: audioStore, diagnostics: diagnosticRecordStore, backups: backups,
            quarantine: quarantine, storeURL: storeURL)
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

    /// Diagnostic records on disk and their size, for the Settings row. Nil
    /// when their folder would not list: the History pane must not read that
    /// as nothing to delete (#1166). The folder failed, not the store, so
    /// History is not marked as failing.
    func diagnosticRecordSummary() async -> (records: Int, bytes: Int)? {
        guard let diagnosticRecordStore else { return (0, 0) }
        return await read("summarize diagnostic records") { _ in
            Self.summarize("diagnostic records") { try diagnosticRecordStore.summary() }
        } ?? nil
    }


    /// Nil when the audio folder would not list, like the records'.
    func audioSummary() async -> (recordings: Int, bytes: Int)? {
        guard let audioStore else { return (0, 0) }
        return await read("summarize dictation audio") { _ in
            Self.summarize("dictation audio") { try audioStore.summary() }
        } ?? nil
    }

    private nonisolated static func summarize<Summary>(
        _ label: String, _ body: () throws -> Summary
    ) -> Summary? {
        do {
            return try body()
        } catch {
            Log.persistence.error(
                "History: listing \(label, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
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

/// What a trim or a sweep may touch besides the store, captured for the
/// write queue.
private struct SweptAttachments: Sendable {
    let audio: DictationAudioStore?
    let diagnostics: DiagnosticRecordStore?
    let backups: DictationHistoryBackups?
    let quarantine: DictationHistoryQuarantine?
    let storeURL: URL?

    func snapshotBeforeDelete() {
        guard let backups, let storeURL else { return }
        backups.snapshotBeforeDelete(of: storeURL)
    }

    func moveStrayAudio(writtenBefore cutoff: Date) {
        guard let audio else { return }
        audio.quarantineStrayFiles(
            writtenBefore: cutoff,
            into: quarantine?.folder(for: "dictation-audio")
                ?? audio.directoryURL.deletingLastPathComponent()
                    .appendingPathComponent("quarantine/unsorted", isDirectory: true))
    }

    /// The attachments whose dictation is gone. Only the ids listed once,
    /// here, are looked up and moved: a file written after the listing is
    /// not in the set, so it cannot be taken for an orphan.
    func sweepOrphans(context: ModelContext) throws {
        let audioIDs = audio?.storedIDs() ?? []
        let diagnosticIDs = diagnostics?.storedIDs() ?? []
        let candidates = audioIDs.union(diagnosticIDs)
        guard !candidates.isEmpty,
              try DictationSessionStore.storeHoldsDictations(context, files: candidates.count)
        else { return }
        let listed = Array(candidates)
        let kept = try Set(context.fetch(FetchDescriptor<DictationSessionRecord>(
            predicate: #Predicate { listed.contains($0.id) })).map(\.id))
        let orphans = candidates.subtracting(kept)
        guard !orphans.isEmpty else { return }
        guard orphans.count <= DictationSessionStore.maximumOrphansPerSweep else {
            Log.persistence.error(
                "History: \(orphans.count, privacy: .public) attachment(s) have no dictation; more than one sweep may move, so keeping them all"
            )
            return
        }
        snapshotBeforeDelete()
        let audioOrphans = orphans.intersection(audioIDs)
        let diagnosticOrphans = orphans.intersection(diagnosticIDs)
        let moved: Int
        if let quarantine {
            moved = (audio?.quarantine(audioOrphans, into: quarantine.folder(for: "dictation-audio")) ?? 0)
                + (diagnostics?.quarantine(
                    diagnosticOrphans, into: quarantine.folder(for: "diagnostic-records")) ?? 0)
        } else {
            moved = (audio?.remove(audioOrphans) ?? 0) + (diagnostics?.remove(diagnosticOrphans) ?? 0)
        }
        if moved > 0 {
            Log.persistence.info(
                "History: moved \(moved, privacy: .public) attachment(s) whose dictation is gone out of the store's folders"
            )
        }
    }
}
