import Foundation

/// Says where in a stream of 16 kHz audio somebody speaks, from loudness alone, for
/// `PauseGate` (LVX-126).
///
/// The audio is pre-emphasised (speech keeps most of its level, fan and room rumble
/// lose theirs) and measured in 10 ms sub-frames. A sub-frame is loud when it stands
/// `marginDB` over a noise floor that drops to any quieter level at once and rises
/// `floorRiseDBPerSecond` otherwise, so it follows the room between words. Speech is a
/// run of `loudRun` loud sub-frames: a key click is shorter.
///
/// On 203 of the owner's dictations (4.3 h) these settings let the gate drop 10.6% of
/// the audio, against 12.7% with Silero VAD, and full-band loudness without the
/// pre-emphasis only 1.8% (localvoxtral-planning, research/perf-voxtral-heat-2026-11.md).
public struct SpeechLevelDetector: Sendable {
    public static let subFrameSamples = 160

    public var marginDB = 9.0
    public var loudRun = 3
    public var floorRiseDBPerSecond = 2.0
    /// Below this a sub-frame is digital silence, which must not pull the floor down
    /// to where every later sound reads as speech.
    public var quietestDB = -75.0

    private var floorDB = -50.0
    private var previousSample: Float = 0
    private var sumOfSquares = 0.0
    private var samplesInSubFrame = 0
    private var run = 0

    public init() {}

    /// Takes the next samples of the stream. Returns how many of them had gone by when
    /// the last speech in them ended, or nil when they hold none.
    public mutating func process(_ samples: [Float]) -> Int? {
        var lastSpeechEnd: Int?
        for (index, sample) in samples.enumerated() {
            let emphasised = Double(sample - 0.97 * previousSample)
            previousSample = sample
            sumOfSquares += emphasised * emphasised
            samplesInSubFrame += 1
            guard samplesInSubFrame == Self.subFrameSamples else { continue }
            let meanSquare = sumOfSquares / Double(Self.subFrameSamples)
            sumOfSquares = 0
            samplesInSubFrame = 0
            let level = max(quietestDB, meanSquare > 0 ? 10 * log10(meanSquare) : quietestDB)
            floorDB = level < floorDB
                ? level
                : floorDB + floorRiseDBPerSecond * Double(Self.subFrameSamples) / 16_000
            if level > floorDB + marginDB {
                run += 1
                if run >= loudRun { lastSpeechEnd = index + 1 }
            } else {
                run = 0
            }
        }
        return lastSpeechEnd
    }
}
