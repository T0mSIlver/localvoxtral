/// Accumulates 16 kHz audio and yields fixed-cadence batches for streaming inference.
///
/// The realtime client normally appends 100 ms chunks, while Voxtral's native streaming
/// cadence is 480 ms. Batching here avoids rerunning the model front end for every network
/// append without changing the audio presented to the stream session.
public struct StepBatcher: Sendable {
    public let samplesPerStep: Int
    private var bufferedSamples: [Float] = []

    public init(cadenceMilliseconds: Int, sampleRate: Int = 16_000) {
        precondition(cadenceMilliseconds > 0, "cadenceMilliseconds must be positive")
        precondition(sampleRate > 0, "sampleRate must be positive")
        let (product, overflow) = sampleRate.multipliedReportingOverflow(
            by: cadenceMilliseconds
        )
        precondition(!overflow, "cadence is too large")
        self.samplesPerStep = max(1, product / 1_000)
    }

    public var bufferedSampleCount: Int { bufferedSamples.count }

    /// Append samples and return every complete cadence-sized batch now due.
    /// A large append can produce more than one batch; any short tail remains buffered.
    public mutating func append(_ samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return [] }
        bufferedSamples.append(contentsOf: samples)

        let batchCount = bufferedSamples.count / samplesPerStep
        guard batchCount > 0 else { return [] }

        var batches: [[Float]] = []
        batches.reserveCapacity(batchCount)
        var start = 0
        for _ in 0..<batchCount {
            let end = start + samplesPerStep
            batches.append(Array(bufferedSamples[start..<end]))
            start = end
        }
        bufferedSamples.removeFirst(start)
        return batches
    }

    /// Return the sub-cadence tail, if any, and empty the batcher.
    public mutating func flushRemainder() -> [Float] {
        guard !bufferedSamples.isEmpty else { return [] }
        let remainder = bufferedSamples
        bufferedSamples.removeAll(keepingCapacity: true)
        return remainder
    }

    public mutating func clear() {
        bufferedSamples.removeAll(keepingCapacity: true)
    }
}
