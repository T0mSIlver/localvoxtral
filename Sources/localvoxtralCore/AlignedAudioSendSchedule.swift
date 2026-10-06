import Foundation

/// Where the send loop cuts the microphone audio for the managed speech helper
/// (#1670).
///
/// Both catalog engines decode a token only once the audio reaches a few ms
/// past its 80 ms boundary: Voxtral 10 ms, Nemotron 6 ms past the end of each
/// chunk. The helper steps on what an append brings, but holds an append
/// shorter than its 80 ms minimum step until the next one arrives. A timer
/// that drains whole mic buffers every 80 ms falls short of that minimum on
/// about every other tick, and lands at a random point between two tokens.
///
/// So the loop sends exactly up to the next 80 ms boundary plus 10 ms, as soon
/// as the microphone has captured it: every append after the first is 80 ms
/// long and arrives just after a token became decodable.
package struct AlignedAudioSendSchedule: Sendable {
    package static let samplesPerStep = 1_280
    package static let offsetSamples = 160
    private static let sampleRate = 16_000
    private static let bytesPerSample = 2
    /// The mic delivers in buffers of about 10 ms; waking sooner finds nothing new.
    private static let shortestWait = Duration.milliseconds(1)

    package enum Action: Equatable, Sendable {
        /// Send this many bytes from the front of the buffer.
        case send(byteCount: Int)
        /// The next boundary is not captured yet; check again after this long.
        case wait(Duration)
    }

    /// Samples this connection has sent: where the helper's token grid stands.
    package private(set) var sentSamples = 0

    package init() {}

    /// What to do with `bufferedBytes` of 16 kHz PCM16 waiting to be sent.
    package func next(bufferedBytes: Int) -> Action {
        let captured = sentSamples + bufferedBytes / Self.bytesPerSample
        let due = Self.boundary(atLeast: sentSamples + Self.samplesPerStep)
        guard captured >= due else {
            let missing = due - captured
            let wait = Duration.microseconds((missing * 1_000_000 + Self.sampleRate - 1) / Self.sampleRate)
            return .wait(max(wait, Self.shortestWait))
        }
        // A backlog (the audio captured while the socket opened, or a
        // reconnect's replay) goes in one append, up to the last boundary.
        let end = Self.boundary(atMost: captured)
        return .send(byteCount: (end - sentSamples) * Self.bytesPerSample)
    }

    package mutating func didSend(byteCount: Int) {
        sentSamples += byteCount / Self.bytesPerSample
    }

    private static func boundary(atLeast samples: Int) -> Int {
        let steps = (samples - offsetSamples + samplesPerStep - 1) / samplesPerStep
        return steps * samplesPerStep + offsetSamples
    }

    private static func boundary(atMost samples: Int) -> Int {
        (samples - offsetSamples) / samplesPerStep * samplesPerStep + offsetSamples
    }
}
