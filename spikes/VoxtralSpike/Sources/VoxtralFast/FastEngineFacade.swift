import Foundation

/// Public facade over the vendored (and optimized) Voxtral engine.
///
/// The vendored sources keep their upstream access levels, which are module-internal;
/// this exposes just what the spike harness drives, so the harness can measure the stock
/// engine (MLXAudioSTT) and this one through identical code.
public final class FastEngine {
    private let model: VoxtralRealtimeModel

    public init(repo: String) async throws {
        model = try await VoxtralRealtimeModel.fromPretrained(repo)
    }

    public func makeSession(temperature: Float = 0.0, transcriptionDelayMs: Int?) -> FastSession {
        FastSession(
            model.makeStreamSession(
                temperature: temperature,
                transcriptionDelayMs: transcriptionDelayMs
            )
        )
    }
}

public final class FastSession {
    private let session: VoxtralRealtimeStreamSession

    init(_ session: VoxtralRealtimeStreamSession) {
        self.session = session
    }

    /// Text decoded by this chunk.
    public func step(_ samples: [Float]) -> String { session.step(samples).text }
    /// Flush the tail; returns the final fragment.
    public func finish() -> String { session.finish().text }
    /// Full transcript so far.
    public var text: String { session.text }
}
