import Foundation

/// Stateful, append-only wrapper over `StreamingDelta` for a single transcript stream.
///
/// The realtime server feeds this the streaming session's FULL transcript snapshot
/// (`session.text`) after every `step` / `finish`, and puts only the returned delta on the
/// wire. This is where the append-only delta contract lives now that the Voxtral engine is
/// an upstream dependency: upstream's own `Delta` re-emits the whole transcript on any
/// non-prefix step (e.g. when a split multi-byte character resolves), and feeding those raw
/// deltas to our no-backspace insertion path would duplicate text on screen. Routing the
/// full-text snapshot through `StreamingDelta` here reproduces exactly what the previously
/// vendored engine did internally (LOCAL FIX #6), but in a Metal-free, unit-testable layer.
///
/// Pure value type: hold one per connection, feed snapshots in order, emit each delta.
public struct TranscriptDeltaEmitter: Equatable, Sendable {
    private var emitted = ""
    /// Number of divergences held back (a snapshot that was not a forward extension of what
    /// was already emitted, beyond a provisional trailing char). Should stay 0 at
    /// temperature 0; surfaced for observability.
    public private(set) var rewriteCount = 0

    public init() {}

    /// The full running text already put on the wire (== the concatenation of every delta
    /// returned so far). Use this for the authoritative `transcript.done` payload so it can
    /// never contradict the append-only stream.
    public var emittedText: String { emitted }

    /// Feed the latest full-transcript snapshot; returns the append-only delta to emit.
    /// Empty when nothing new is stable yet (a provisional trailing char is held back) or on
    /// a held-back divergence.
    public mutating func emit(fullText: String) -> String {
        let step = StreamingDelta.next(previouslyEmitted: emitted, fullText: fullText)
        emitted = step.emitted
        if step.wasRewrite { rewriteCount += 1 }
        return step.delta
    }
}
