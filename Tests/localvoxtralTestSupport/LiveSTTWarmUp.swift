import Foundation
import Synchronization
import localvoxtralCore

/// Pays the live STT service's first-utterance cost before the tests that
/// time an utterance (#1122). `lv-test-servers.sh ensure` and `/health` only
/// show that the helper listens; after an idle stretch on a loaded Mac the
/// first utterance also waits for the model to page back in. In release run
/// 36753878977 that pushed the voice memo, the job's first utterance after
/// 14 idle minutes, past its 38 s bound; the rerun, 5 minutes after the last
/// use, answered in 5.7 s.
package enum LiveSTTWarmUp {
    /// For a short phrase on a cold service under load.
    package static let bound: Duration = .seconds(120)

    private static let warmUp = Mutex<Task<Duration, any Error>?>(nil)

    /// Once per test process: a short spoken phrase through the file
    /// transcriber, bounded by `bound` instead of the file's own timeout.
    /// Returns how long the first call took; later calls wait for it, and a
    /// failure fails every caller.
    package static func once(configuration: RealtimeSessionConfiguration) async throws -> Duration {
        let task = warmUp.withLock { task in
            if let task { return task }
            let started = Task { try await run(configuration) }
            task = started
            return started
        }
        return try await task.value
    }

    private static func run(_ configuration: RealtimeSessionConfiguration) async throws -> Duration {
        #if os(macOS)
        let pcm = try IntegrationTestSupport.makeSpokenPCM16Data(phrase: "warming up the speech service")
        // The transcriber's only sleep is its timeout.
        let clock = SessionClock(sleep: { _ in try? await Task.sleep(for: bound) }, now: { Date() })
        let started = ContinuousClock.now
        _ = try await RealtimeFileTranscriber(makeClient: { RealtimeAPIWebSocketClient() }, clock: clock)
            .transcribe(pcm16: pcm, configuration: configuration)
        let elapsed = ContinuousClock.now - started
        print("live STT warm-up: answered in \(elapsed)")
        return elapsed
        #else
        return .zero
        #endif
    }
}
