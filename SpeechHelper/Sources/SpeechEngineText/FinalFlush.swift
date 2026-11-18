import Foundation

/// The final commit's steps, one batch at a time. The caller's `send` puts each delta on
/// the wire as soon as its step ends, so the app's finalization timeout can only cut off
/// the batches still to come (LVX-59). A closed feed stops the work between steps, so a
/// disconnected client does not hold the serial inference queue for the rest of its
/// remainder (LVX-60).
public enum FinalFlush {
    /// Steps every remaining batch, then `finish()`. Returns false when the feed closed
    /// first: `finish()` did not run and the caller sends no `done`.
    /// - Parameter beforeFinish: runs after the last batch, before `finish()`.
    public static func run(
        session: SpeechASRStreamingSession,
        feed: CoalescingStepFeed,
        deltas: inout TranscriptDeltaEmitter,
        send: (String) -> Void,
        didStep: (_ batch: [Float], _ duration: Duration, _ producedText: Bool) -> Void = { _, _, _ in },
        beforeFinish: () -> Void
    ) -> Bool {
        for batch in feed.flushRemainder() {
            guard !feed.isClosed else { return false }
            let duration = ContinuousClock().measure { session.step(batch) }
            let delta = deltas.emit(fullText: session.text)
            if !delta.isEmpty { send(delta) }
            didStep(batch, duration, !delta.isEmpty)
        }
        guard !feed.isClosed else { return false }
        beforeFinish()
        session.finish()
        let tail = deltas.emit(fullText: session.text)
        if !tail.isEmpty { send(tail) }
        return !feed.isClosed
    }
}
