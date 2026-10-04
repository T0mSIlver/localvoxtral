import Foundation

/// How long one polish request may take before the client gives up, scaled
/// with the transcript it carries (#318).
///
/// The floor is the old flat timeout. It was sized for the fixed part of every
/// request: a 4B model whose polishd prefix-cache checkpoint was invalidated
/// re-prefills the ~2.3k-token prompt, which took 23.6 s on a real request and
/// outlived the 15 s timeout before it (field, 2026-07-11).
///
/// On top of the floor, each transcript token adds time twice, because the
/// model reads it in and then writes roughly as much back out:
/// - reading: the field point above works out to ~10 ms per prefilled token;
///   the slope doubles it for headroom, 20 ms.
/// - writing: polish output is about as long as its input, and decoding a
///   token is slower than prefilling one; 30 ms per token (~33 tokens/s) is an
///   assumption, not a measurement.
///
/// Both slopes rest on that single field point. polishd has not been timed on
/// a ~1,500-word or a ~9,000-word transcript yet; that measurement is still
/// owed (#318), and the slope and ceiling should be refit from it.
///
/// Tokens are estimated as characters / 4, the usual rule of thumb for English
/// text with a BPE tokenizer; no tokenizer runs on the client.
package enum PolishRequestTimeout {
    /// The whole budget for a request with an empty transcript.
    package static let floorSeconds: TimeInterval = 40

    /// No polish waits longer than this, however long the transcript. It is
    /// reached at ~5,200 tokens (~3,500 words); a longer dictation gets 300 s
    /// and may still time out, which the owed measurement will tell.
    package static let ceilingSeconds: TimeInterval = 300

    /// Prefill (20 ms) plus output (30 ms) per transcript token.
    package static let secondsPerTranscriptToken: TimeInterval = 0.050

    package static let charactersPerToken = 4

    /// The request's timeout. An explicit `override` (a caller that knows its
    /// request is not a polish, such as term suggestions) wins unchanged.
    package static func seconds(
        forInputCharacters characters: Int,
        override: TimeInterval? = nil
    ) -> TimeInterval {
        if let override {
            return override
        }
        let clamped = max(0, characters)
        let tokens = clamped / charactersPerToken + (clamped % charactersPerToken == 0 ? 0 : 1)
        let scaled = floorSeconds + Double(tokens) * secondsPerTranscriptToken
        return min(ceilingSeconds, scaled)
    }
}

/// What `PolishRequestTimeout.enforcing` throws when the request ran past its
/// whole budget.
package struct PolishDeadlinePassed: Error, Equatable {
    package let seconds: TimeInterval
}

extension PolishRequestTimeout {
    /// Runs `request` for at most `seconds` in all, then cancels it and throws
    /// `PolishDeadlinePassed`. `URLRequest.timeoutInterval` measures idle
    /// time: a server that sends a byte now and then would otherwise hold
    /// the request, and the stop commit waiting on it, for the session's
    /// seven-day resource timeout (#1688).
    package static func enforcing<T: Sendable>(
        seconds: TimeInterval,
        sleep: @escaping @Sendable (Duration) async -> Void,
        _ request: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await request() }
            group.addTask {
                await sleep(.seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            if let value = first { return value }
            // The sleep returns early when the caller is cancelled.
            try Task.checkCancellation()
            throw PolishDeadlinePassed(seconds: seconds)
        }
    }
}
