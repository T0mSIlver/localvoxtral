import Foundation
import Synchronization

/// How loud the mic is, for the overlay's level bars (#1074). Fed every
/// captured chunk on the capture queue; answers a smoothed level at most
/// `postsPerSecond` times a second of audio, which the caller hands to the
/// main actor.
///
/// Time is measured in audio, not on the clock: a chunk of n samples moves
/// the meter n / 16 000 s. So the smoothing is the same on any machine and a
/// test drives it with plain chunks.
package final class MicLevelMeter: Sendable {
    /// Loudness at or below this rests the bars: room noise on a laptop mic
    /// sits around -60 dBFS.
    package static let floorDB = -55.0
    /// Loudness at or above this fills them: close speech peaks near -10.
    package static let ceilingDB = -12.0
    /// Rise and fall time constants: the bars jump with a syllable and sink
    /// over about a quarter second, so they neither lag speech nor flicker.
    package static let attackSeconds = 0.03
    package static let releaseSeconds = 0.25
    /// Enough for motion to read as smooth; SwiftUI animates between posts.
    package static let postsPerSecond = 30.0

    private struct State {
        var level = 0.0
        var secondsSincePost = Double.infinity
    }

    private let state = Mutex(State())

    package init() {}

    /// The smoothed level after `chunk`, 0...1, or nil when the last post
    /// was less than 1 / `postsPerSecond` of audio ago.
    package func ingest(pcm16 chunk: Data) -> Double? {
        let samples = chunk.count / 2
        guard samples > 0 else { return nil }
        let target = Self.loudness(pcm16: chunk)
        let elapsed = Double(samples) / Double(DictationAudioRecording.sampleRate)
        return state.withLock { state in
            let timeConstant = target > state.level ? Self.attackSeconds : Self.releaseSeconds
            state.level += (target - state.level) * (1 - exp(-elapsed / timeConstant))
            state.secondsSincePost += elapsed
            guard state.secondsSincePost >= 1 / Self.postsPerSecond else { return nil }
            state.secondsSincePost = 0
            return state.level
        }
    }

    /// Loudness of one PCM16 mono little-endian chunk on the bars' scale:
    /// its RMS in dBFS, mapped from `floorDB`...`ceilingDB` onto 0...1.
    package static func loudness(pcm16 chunk: Data) -> Double {
        let samples = chunk.count / 2
        guard samples > 0 else { return 0 }
        var sumOfSquares = 0.0
        chunk.withUnsafeBytes { raw in
            for index in 0..<samples {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                sumOfSquares += sample * sample
            }
        }
        let rms = (sumOfSquares / Double(samples)).squareRoot() / Double(Int16.max)
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - floorDB) / (ceilingDB - floorDB)))
    }
}
