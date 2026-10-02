import Synchronization

/// Sizes the server's streaming steps to what the GPU keeps up with, with no setting.
///
/// Every audio append the network side queues for the inference queue calls
/// `audioQueued()` first; the inference side hands the append's samples to
/// `receive(_:)`. `receive` returns a batch only when no later append is already
/// queued behind it, and then returns everything buffered. So a step covers the
/// audio that arrived while the previous step ran: `minimumSamples` while steps
/// finish in time, larger when they don't, and never a backlog of small steps
/// queued behind a slow one.
///
/// No batch exceeds `maximumSamples`. A step cannot be interrupted, and every
/// connection shares one inference queue, so an uncapped step over a voice
/// memo's whole backlog would hold a live dictation's audio until the memo is
/// done (#1317). Once `close()`d, the feed hands out nothing: a connection that
/// closed skips its queued appends and leaves the queue to the next one.
///
/// Deferring to a queued append is always safe: that append, or a commit or clear
/// dispatched after it, runs on the same serial queue and flushes the buffer.
public final class CoalescingStepFeed: Sendable {
    /// The smallest step, in samples. 80 ms is one Voxtral token and one Nemotron
    /// encoder frame; less audio than that cannot produce new text.
    public let minimumSamples: Int
    /// The largest step, in samples: how long a live dictation can wait behind
    /// another connection's step.
    public let maximumSamples: Int

    /// 2 s: large enough that a memo's steps keep its speed; a dictation started
    /// during one waits for one step over 2 s of audio at most.
    public static let defaultMaximumMilliseconds = 2_000

    private struct State {
        var queuedAppends = 0
        var buffered: [Float] = []
        var largestStepSamples = 0
        var isClosed = false
    }

    private let state = Mutex(State())

    public init(
        minimumMilliseconds: Int,
        maximumMilliseconds: Int = defaultMaximumMilliseconds,
        sampleRate: Int = 16_000
    ) {
        precondition(minimumMilliseconds > 0, "minimumMilliseconds must be positive")
        precondition(maximumMilliseconds >= minimumMilliseconds, "maximumMilliseconds must not be below the minimum")
        precondition(sampleRate > 0, "sampleRate must be positive")
        let (minimum, overflow) = sampleRate.multipliedReportingOverflow(by: minimumMilliseconds)
        let (maximum, maximumOverflow) = sampleRate.multipliedReportingOverflow(by: maximumMilliseconds)
        precondition(!overflow && !maximumOverflow, "step is too large")
        self.minimumSamples = max(1, minimum / 1_000)
        self.maximumSamples = max(minimumSamples, maximum / 1_000)
    }

    /// Network side: call once per append, before dispatching it to the inference queue.
    public func audioQueued() {
        state.withLock { $0.queuedAppends += 1 }
    }

    /// Inference side: call exactly once per `audioQueued()`, in order. Returns the
    /// batch to step now, or nil when a later append will take it. A full
    /// `maximumSamples` is stepped even with appends queued behind it.
    public func receive(_ samples: [Float]) -> [Float]? {
        state.withLock { state in
            state.queuedAppends -= 1
            guard !state.isClosed else { return nil }
            state.buffered.append(contentsOf: samples)
            guard state.buffered.count >= maximumSamples
                || (state.queuedAppends == 0 && state.buffered.count >= minimumSamples)
            else {
                return nil
            }
            let batch = Array(state.buffered.prefix(maximumSamples))
            state.buffered.removeFirst(batch.count)
            state.largestStepSamples = max(state.largestStepSamples, batch.count)
            return batch
        }
    }

    /// Whatever is buffered, any length, for the final steps of an utterance: one
    /// batch per `maximumSamples`.
    public func flushRemainder() -> [[Float]] {
        state.withLock { state in
            let remainder = state.buffered
            state.buffered.removeAll(keepingCapacity: true)
            return stride(from: 0, to: remainder.count, by: maximumSamples).map {
                Array(remainder[$0 ..< min($0 + maximumSamples, remainder.count)])
            }
        }
    }

    /// Drop the buffered audio. Appends already queued still call `receive`.
    public func clear() {
        state.withLock { $0.buffered.removeAll(keepingCapacity: true) }
    }

    /// The connection closed: drop the buffered audio, and from now on hand out
    /// nothing. Appends already queued still call `receive`.
    public func close() {
        state.withLock { state in
            state.isClosed = true
            state.buffered.removeAll()
        }
    }

    public var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    /// The largest step since the last call, then reset: one number per utterance
    /// for the helper log.
    public func takeLargestStepSamples() -> Int {
        state.withLock { state in
            let largest = state.largestStepSamples
            state.largestStepSamples = 0
            return largest
        }
    }
}
