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
    func writeDogfoodCaptureIfArmed(_ inputs: DogfoodCaptureInputs) async {
        let abstentions = DogfoodCaptureTap.shared.consumeJoinAbstentions()
        let repoVocabularyHarvest = DogfoodCaptureTap.shared.consumeRepoVocabularyHarvest()
        guard settings.dogfoodCaptureEnabled else { return }

        var inputs = inputs
        inputs.joinAbstentions = abstentions
        inputs.repoVocabularyHarvest = repoVocabularyHarvest
        let store = dogfoodCaptureStore
        let started = ContinuousClock.now

        // Assembly walks complete retained buffers (harvest re-derivation);
        // `build` is nonisolated, so this await hops off the main actor the
        // same way the preparations it mirrors do.
        var record = await Self.assembleDogfoodRecord(inputs: inputs)
        let elapsed = (ContinuousClock.now - started).components
        record.timings.captureMilliseconds =
            Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        await DogfoodCaptureWriter.write(record, store: store)
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
