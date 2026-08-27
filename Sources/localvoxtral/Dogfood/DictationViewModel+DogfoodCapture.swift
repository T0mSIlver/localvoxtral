#if LOCALVOXTRAL_DOGFOOD

import Foundation

extension DictationViewModel {
    /// Writes this dictation's capture record, or does nothing at all.
    ///
    /// Called from the polish commit path AFTER the text was committed and the
    /// session record saved — the capture can add latency only to the tail of
    /// the task, never to the user's paste. The runtime opt-in is checked
    /// first, before any harvest re-derivation, so an instrumented build that
    /// is not armed does no extra work beyond this one Bool read.
    ///
    /// The tap is consumed EVEN when disarmed — its slots must not carry one
    /// session's facts into a later, armed session's record.
    ///
    /// `commitOutcome` gates the edit watch: only `.succeeded` put text in
    /// front of the user, so only `.succeeded` is watchable. `.failed` and
    /// `.copiedToClipboard` left nothing in the target app — a Backspace
    /// there would be recorded as erasing an insertion that never happened,
    /// and an uneventful window would pad the `clean` denominator.
    ///
    /// `committedTextForWatch` is the payload-SUBSTITUTED commit copy,
    /// measured and discarded (the watcher keeps only its word-count bucket):
    /// the window must scale with what was actually inserted — a 100-word
    /// paste takes far longer to judge than its one-token placeholder — while
    /// the record itself keeps only placeholder-bearing text. The clipboard
    /// payload must not enter the record through this parameter.
    func writeDogfoodCaptureIfArmed(
        _ inputs: DogfoodCaptureInputs,
        commitOutcome: OverlayBufferCommitOutcome,
        committedTextForWatch: String
    ) async {
        let abstentions = DogfoodCaptureTap.shared.consumeJoinAbstentions()
        let repoVocabularyHarvest = DogfoodCaptureTap.shared.consumeRepoVocabularyHarvest()
        guard settings.dogfoodCaptureEnabled else { return }
        // A stopped-with-no-speech session skipped the polish call and has
        // nothing to attribute; a record of empty stages is retention noise.
        guard !inputs.text.workingText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        var inputs = inputs
        inputs.joinAbstentions = abstentions
        inputs.repoVocabularyHarvest = repoVocabularyHarvest
        let store = dogfoodCaptureStore
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
        let watchToken: DogfoodEditSignalWatcher.WatchToken?
        if case .succeeded = commitOutcome {
            watchToken = dogfoodEditSignalWatcher.arm(
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
        var record = await Self.assembleDogfoodRecord(inputs: inputs)
        let elapsed = (ContinuousClock.now - started).components
        record.timings.captureMilliseconds =
            Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        // The watch is already open; this only tells it which record to patch.
        // A failed write leaves it open until its window closes, where it finds
        // no record and flushes nothing — the signal costs the record, never
        // the other way around.
        let url = await DogfoodCaptureWriter.write(record, store: store)
        if let url, let watchToken {
            dogfoodEditSignalWatcher.attachRecord(url: url, store: store, token: watchToken)
        }
    }

    private nonisolated static func assembleDogfoodRecord(
        inputs: DogfoodCaptureInputs
    ) async -> DogfoodCaptureRecord {
        DogfoodCaptureBuilder.build(
            id: UUID().uuidString,
            capturedAt: Date(),
            inputs: inputs
        )
    }
}

#endif
