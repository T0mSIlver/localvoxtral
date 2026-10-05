/// Accumulates 16 kHz audio and yields the batches `speechd-bench` steps on.
///
/// By default the bench steps at a fixed cadence, which is what the server's
/// `CoalescingStepFeed` does on a Mac that keeps up with its minimum step. A larger
/// cadence shows what bigger steps cost and delay.
///
/// A phase moves every step boundary `phase` ms past a cadence multiple: the first
/// batch carries `cadence + phase` ms. Both engines can decode a token only a few
/// ms after its 80 ms boundary, so at an 80 ms cadence the phase decides how long
/// every word waits (#1670).
///
/// A mic buffer models the app instead: its send timer fires every `cadence` ms
/// and drains only the whole mic buffers captured by then, and the server holds an
/// append shorter than its minimum step until the next one arrives. A batch then
/// arrives at its timer tick, not at its last sample.
public struct StepBatcher: Sendable {
    /// One step's audio and when it reaches the server, in samples from the start.
    public struct Batch: Equatable, Sendable {
        public let samples: [Float]
        public let arrivalSample: Int
    }

    public let samplesPerStep: Int
    public let phaseSamples: Int
    /// Samples per mic buffer; 0 steps on exact cadence boundaries.
    public let micBufferSamples: Double
    /// Shorter batches wait for the next tick, as `CoalescingStepFeed` holds them.
    public let minimumSamples: Int
    private var bufferedSamples: [Float] = []
    /// Absolute index of `bufferedSamples[0]`.
    private var consumedSamples = 0
    private var nextTick = 1

    public init(
        cadenceMilliseconds: Int,
        phaseMilliseconds: Int = 0,
        micBufferMicroseconds: Int = 0,
        minimumMilliseconds: Int = 0,
        sampleRate: Int = 16_000
    ) {
        precondition(cadenceMilliseconds > 0, "cadenceMilliseconds must be positive")
        precondition(phaseMilliseconds >= 0, "phaseMilliseconds must not be negative")
        precondition(micBufferMicroseconds >= 0, "micBufferMicroseconds must not be negative")
        precondition(minimumMilliseconds >= 0, "minimumMilliseconds must not be negative")
        precondition(sampleRate > 0, "sampleRate must be positive")
        func samples(_ milliseconds: Int, _ what: String) -> Int {
            let (product, overflow) = sampleRate.multipliedReportingOverflow(by: milliseconds)
            precondition(!overflow, "\(what) is too large")
            return product / 1_000
        }
        self.samplesPerStep = max(1, samples(cadenceMilliseconds, "cadence"))
        self.phaseSamples = samples(phaseMilliseconds, "phase")
        self.micBufferSamples = Double(micBufferMicroseconds) * Double(sampleRate) / 1_000_000
        self.minimumSamples = samples(minimumMilliseconds, "minimum")
    }

    public var bufferedSampleCount: Int { bufferedSamples.count }

    /// Append samples and return every batch now due, in order.
    /// A large append can produce more than one batch; any short tail remains buffered.
    public mutating func append(_ samples: [Float]) -> [Batch] {
        guard !samples.isEmpty else { return [] }
        bufferedSamples.append(contentsOf: samples)
        let received = consumedSamples + bufferedSamples.count

        var batches: [Batch] = []
        var start = 0
        while true {
            let tick = phaseSamples + nextTick * samplesPerStep
            guard tick <= received else { break }
            nextTick += 1
            let end = drainedSamples(atTick: tick)
            guard end - (consumedSamples + start) >= max(1, minimumSamples) else { continue }
            let relativeEnd = end - consumedSamples
            batches.append(Batch(
                samples: Array(bufferedSamples[start..<relativeEnd]),
                arrivalSample: tick
            ))
            start = relativeEnd
        }
        bufferedSamples.removeFirst(start)
        consumedSamples += start
        return batches
    }

    /// Return the sub-cadence tail, if any, and empty the batcher.
    public mutating func flushRemainder() -> [Float] {
        guard !bufferedSamples.isEmpty else { return [] }
        let remainder = bufferedSamples
        consumedSamples += bufferedSamples.count
        bufferedSamples.removeAll(keepingCapacity: true)
        return remainder
    }

    public mutating func clear() {
        bufferedSamples.removeAll(keepingCapacity: true)
        consumedSamples = 0
        nextTick = 1
    }

    /// The audio the app has captured when its timer fires at `tick`: whole mic buffers only.
    private func drainedSamples(atTick tick: Int) -> Int {
        guard micBufferSamples > 0 else { return tick }
        let buffers = (Double(tick) / micBufferSamples).rounded(.down)
        return Int((buffers * micBufferSamples).rounded(.down))
    }
}
