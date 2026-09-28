import Foundation

extension DictationSessionController {
    /// Writes this dictation's diagnostic record, or does nothing at all.
    ///
    /// Called from the polish commit path AFTER the text was committed and the
    /// History entry saved — the record can add latency only to the tail of
    /// the task, never to the user's paste. The switch is checked first, before
    /// any harvest re-derivation, so with records off this costs one Bool read.
    ///
    /// `historyID` is the id of the History entry just saved, and becomes the
    /// record's: nil means no entry was saved (History is "Don't keep", or
    /// the dictation was empty), and then no record is written either.
    ///
    /// The tap is consumed EVEN when nothing is written — its slots must not
    /// carry one session's facts into a later session's record.
    ///
    /// `commitOutcome` gates the edit watch: only `.succeeded` put text in
    /// front of the user, so only `.succeeded` is watchable. `.failed` and
    /// `.copiedToClipboard` left nothing in the target app — a Backspace
    /// there would be recorded as erasing an insertion that never happened,
    /// and an uneventful window would pad the `clean` denominator. Nil means
    /// the text went to a named session rather than the focused app (an
    /// addressed send): a Backspace in the focused app says nothing about it.
    ///
    /// `committedTextForWatch` is the payload-SUBSTITUTED commit copy,
    /// measured and discarded (the watcher keeps only its word-count bucket):
    /// the window must scale with what was actually inserted — a 100-word
    /// paste takes far longer to judge than its one-token placeholder — while
    /// the record itself keeps only placeholder-bearing text. The clipboard
    /// payload must not enter the record through this parameter.
    func writeDiagnosticRecordIfEnabled(
        _ inputs: DiagnosticRecordInputs,
        historyID: UUID?,
        commitOutcome: OverlayBufferCommitOutcome?,
        committedTextForWatch: String
    ) async {
        let abstentions = DiagnosticCaptureTap.shared.consumeJoinAbstentions()
        let repoVocabularyHarvest = DiagnosticCaptureTap.shared.consumeRepoVocabularyHarvest()
        guard diagnosticRecordsWanted, let historyID, let store = diagnosticRecordStore else { return }
        // A stopped-with-no-speech session skipped the polish call and has
        // nothing to attribute; a record of empty stages is retention noise.
        guard !inputs.text.workingText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        var inputs = inputs
        inputs.joinAbstentions = abstentions
        inputs.repoVocabularyHarvest = repoVocabularyHarvest
        let started = ContinuousClock.now

        // BEFORE assembly, not after the write: the watch window measures from
        // the commit, and assembly re-derives every harvest off-actor. A user
        // reaching for Backspace during those milliseconds is the strongest
        // signal there is, and arming after the write would be exactly the
        // window that misses it.
        //
        // The token names THIS dictation's watch. It has to be carried across
        // the write below, because that write is awaited and the next dictation
        // can arm in the meantime — an untokened attach would hand this
        // record's URL to that session's window.
        let watchToken: EditSignalWatcher.WatchToken?
        // Set here rather than once: tests replace the watcher.
        editSignalWatcher.onOutcome = { [weak self] id, outcome in
            self?.sessionStore?.setEditOutcome(outcome, forDictation: id)
        }
        if case .succeeded? = commitOutcome {
            watchToken = editSignalWatcher.arm(
                committedText: committedTextForWatch,
                outputMode: inputs.session.outputMode
            )
        } else {
            // Unwatchable commit: the record is still written (the pipeline
            // stages happened and stay attributable), with no behavior block.
            watchToken = nil
        }

        // Assembly walks complete retained buffers (harvest re-derivation);
        // `build` is nonisolated, so this await hops off the main actor the
        // same way the preparations it mirrors do.
        var record = await Self.assembleDiagnosticRecord(id: historyID, inputs: inputs)
        let elapsed = (ContinuousClock.now - started).components
        record.timings.captureMilliseconds =
            Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        // Asked again: the switch or History may have gone off during the
        // assembly, and that deleted the folder this would write into. The
        // epoch covers a delete that lands between here and the write.
        guard diagnosticRecordsWanted else { return }
        let epoch = store.deletionEpoch()
        // The watch is already open; this only tells it which record to patch.
        // A failed write leaves it open until its window closes, where it finds
        // no record and flushes nothing — the signal costs the record, never
        // the other way around.
        let finished = record
        let url: URL?
        if let sessionStore {
            // Queued with the History writes, so a delete of this dictation
            // cannot slip between the check above and the file landing.
            url = await sessionStore.writeDiagnosticRecord(forDictation: historyID) {
                DiagnosticRecordWriter.writeSynchronously(finished, store: store, unlessDeletedSince: epoch)
            }
        } else {
            url = await DiagnosticRecordWriter.write(record, store: store, unlessDeletedSince: epoch)
        }
        // The History pane's count and size include this record now.
        if url != nil { sessionStore?.onChange?() }
        if let url, let watchToken {
            editSignalWatcher.attachRecord(url: url, store: store, token: watchToken)
        }
    }

    /// Records are kept only while History keeps dictations: a record is an
    /// attachment to its History entry.
    var diagnosticRecordsWanted: Bool {
        settings.diagnosticRecordsEnabled && settings.dictationHistoryRetention.savesDictations
    }

    private nonisolated static func assembleDiagnosticRecord(
        id: UUID,
        inputs: DiagnosticRecordInputs
    ) async -> DiagnosticRecord {
        DiagnosticRecordBuilder.build(
            id: id.uuidString,
            capturedAt: Date(),
            inputs: inputs
        )
    }
}
