/// Replays benchmark steps as if the audio had arrived in real time, so a bench
/// that steps as fast as the GPU allows can still report when text would have
/// appeared to the user.
///
/// A step starts when its last sample has arrived and the previous step has
/// finished; its text appears when it finishes. A step slower than the cadence
/// therefore delays every later step, as it does in the server.
public struct RealtimeStepTimeline: Sendable, Equatable {
    public let sampleRate: Int
    /// Seconds from the start of the audio at which each word first appeared.
    public private(set) var wordAppearanceSeconds: [Double] = []
    /// The worst wait between a step's last sample arriving and its text appearing.
    public private(set) var maxLagSeconds: Double = 0
    private var lastFinishSeconds: Double = 0

    public init(sampleRate: Int = 16_000) {
        precondition(sampleRate > 0, "sampleRate must be positive")
        self.sampleRate = sampleRate
    }

    public var firstTextSeconds: Double? { wordAppearanceSeconds.first }

    /// Records one step.
    /// - Parameters:
    ///   - audioSamples: samples fed so far, including this step's.
    ///   - latencySeconds: how long this step's compute took.
    ///   - transcript: the session's full transcript after this step.
    public mutating func record(audioSamples: Int, latencySeconds: Double, transcript: String) {
        let arrival = Double(audioSamples) / Double(sampleRate)
        let finish = max(arrival, lastFinishSeconds) + latencySeconds
        lastFinishSeconds = finish
        maxLagSeconds = max(maxLagSeconds, finish - arrival)
        let words = transcript.split(whereSeparator: \.isWhitespace).count
        while wordAppearanceSeconds.count < words {
            wordAppearanceSeconds.append(finish)
        }
    }
}
