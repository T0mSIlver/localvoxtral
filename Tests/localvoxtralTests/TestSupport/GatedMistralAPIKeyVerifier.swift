import Foundation
import Synchronization
@testable import localvoxtral

/// Answers each key check, in the order they start, only
/// when the test releases that check's verdict.
final class GatedMistralAPIKeyVerifier: MistralAPIKeyVerifying {
    private let verdicts: [AsyncStream<MistralAPIKeyVerification>]
    private let releases: [AsyncStream<MistralAPIKeyVerification>.Continuation]
    private let starts: AsyncStream<Void>
    private let startsContinuation: AsyncStream<Void>.Continuation
    private let started = Mutex(0)

    init(checks: Int) {
        let pairs = (0..<checks).map { _ in AsyncStream<MistralAPIKeyVerification>.makeStream() }
        verdicts = pairs.map(\.stream)
        releases = pairs.map(\.continuation)
        (starts, startsContinuation) = AsyncStream.makeStream()
    }

    func answer(check: Int, with verdict: MistralAPIKeyVerification) {
        releases[check].yield(verdict)
    }

    /// Returns once one more check has reached the verifier, so the test
    /// knows which index the next check takes.
    func nextCheckStarted() async {
        for await _ in starts { return }
    }

    func verify(apiKey: String) async -> MistralAPIKeyVerification {
        let index = started.withLock { count in
            defer { count += 1 }
            return count
        }
        startsContinuation.yield()
        for await verdict in verdicts[index] { return verdict }
        return .accepted
    }
}
