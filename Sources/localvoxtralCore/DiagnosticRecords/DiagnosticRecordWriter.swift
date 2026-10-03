import Foundation

/// Writes one record, off the commit path's actor, never throwing into it.
///
/// The capture must be unable to break a dictation: a full disk, a foreign
/// directory owner, or an encoding surprise costs the RECORD (loudly), never
/// the commit. The write itself is synchronous file IO on the generic executor
/// — the user's text was already committed before the capture is assembled.
package enum DiagnosticRecordWriter {
    /// Where the record landed, or nil when the write failed (loudly).
    @discardableResult
    package nonisolated static func write(
        _ record: DiagnosticRecord,
        store: DiagnosticRecordStore,
        unlessDeletedSince epoch: UInt64? = nil
    ) async -> URL? {
        writeSynchronously(record, store: store, unlessDeletedSince: epoch)
    }

    /// The same write, for a caller already off the main actor.
    package nonisolated static func writeSynchronously(
        _ record: DiagnosticRecord,
        store: DiagnosticRecordStore,
        unlessDeletedSince epoch: UInt64? = nil
    ) -> URL? {
        do {
            let url = try store.write(record, unlessDeletedSince: epoch)
            Log.backends.info(
                "Diagnostic record written: \(url.lastPathComponent, privacy: .public)"
            )
            return url
        } catch DiagnosticRecordStore.StoreError.deletedSinceDecision {
            Log.backends.info("Diagnostic record dropped: records were deleted while it was built")
            return nil
        } catch {
            // Loud by convention (AGENTS.md): a silent failure path here means
            // the records quietly stop.
            Log.backends.error(
                "Diagnostic record write failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Patches one already-written record with the post-commit behavior signal.
    /// Off the commit path entirely — by the time this runs the dictation has
    /// been finished for seconds — and, like `write`, it can only ever cost the
    /// record.
    @discardableResult
    package nonisolated static func attach(
        _ behavior: DiagnosticRecord.Behavior,
        toRecordAt url: URL,
        store: DiagnosticRecordStore
    ) async -> Bool {
        attachSynchronously(behavior, toRecordAt: url, store: store)
    }

    /// The same patch, without the hop. Used at app termination, where a `Task`
    /// is not guaranteed to run — see
    /// `EditSignalWatcher.flushForTermination`. The work is one small
    /// JSON rewrite either way; only the caller's urgency differs.
    /// Whether the record took the patch: false when it is gone.
    @discardableResult
    package nonisolated static func attachSynchronously(
        _ behavior: DiagnosticRecord.Behavior,
        toRecordAt url: URL,
        store: DiagnosticRecordStore
    ) -> Bool {
        do {
            try store.attachBehavior(behavior, toRecordAt: url)
            Log.backends.info(
                "Diagnostic record behavior: \(behavior.outcome.rawValue, privacy: .public) (\(behavior.signal?.rawValue ?? "none", privacy: .public), window \(behavior.watchWindowSeconds, privacy: .public)s) -> \(url.lastPathComponent, privacy: .public)"
            )
            return true
        } catch {
            Log.backends.error(
                "Diagnostic record behavior patch failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

