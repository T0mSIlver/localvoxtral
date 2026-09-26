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
/// Deferring to a queued append is always safe: that append, or a commit or clear
/// dispatched after it, runs on the same serial queue and flushes the buffer.
public final class CoalescingStepFeed: Sendable {
    /// The smallest step, in samples. 80 ms is one Voxtral token and one Nemotron
    /// encoder frame; less audio than that cannot produce new text.
    public let minimumSamples: Int

    private struct State {
        var queuedAppends = 0
        var buffered: [Float] = []
        var largestStepSamples = 0
    }

    private let state = Mutex(State())

    public init(minimumMilliseconds: Int, sampleRate: Int = 16_000) {
        precondition(minimumMilliseconds > 0, "minimumMilliseconds must be positive")
        precondition(sampleRate > 0, "sampleRate must be positive")
        let (product, overflow) = sampleRate.multipliedReportingOverflow(by: minimumMilliseconds)
        precondition(!overflow, "minimum step is too large")
        self.minimumSamples = max(1, product / 1_000)
    }

    /// Network side: call once per append, before dispatching it to the inference queue.
    public func audioQueued() {
        state.withLock { $0.queuedAppends += 1 }
    }

    /// Inference side: call exactly once per `audioQueued()`, in order. Returns the
    /// batch to step now, or nil when a later append will take it.
    public func receive(_ samples: [Float]) -> [Float]? {
        state.withLock { state in
            state.queuedAppends -= 1
            state.buffered.append(contentsOf: samples)
            guard state.queuedAppends == 0, state.buffered.count >= minimumSamples else {
                return nil
            }
            let batch = state.buffered
            state.buffered.removeAll(keepingCapacity: true)
            state.largestStepSamples = max(state.largestStepSamples, batch.count)
            return batch
        }
    }

    /// Return whatever is buffered, any length, for the final step of an utterance.
    public func flushRemainder() -> [Float] {
        state.withLock { state in
            let remainder = state.buffered
            state.buffered.removeAll(keepingCapacity: true)
            return remainder
        }
    }

    /// Drop the buffered audio. Appends already queued still call `receive`.
    public func clear() {
        state.withLock { $0.buffered.removeAll(keepingCapacity: true) }
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
