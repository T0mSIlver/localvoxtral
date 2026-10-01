import Foundation
import Synchronization

/// Recorded audio through a streaming realtime socket, as fast as the backend
/// takes it (#925). Every chunk is queued at once and then one final commit,
/// so the bundled helper batches the backlog into larger steps and finishes
/// well ahead of real time. No batch model is involved.
///
/// A memo longer than a vLLM server's context goes through one fresh session
/// per segment, cut at the quietest stretch before the limit (#1148). The
/// client's own rollover is no use here: it reads pauses off live text, and a
/// memo's queued backlog would outlast its wait for the retiring `done`.
package struct RealtimeFileTranscriber: Sendable {
    package enum Failure: Error, Equatable {
        case connectFailed(String)
        case backend(String)
        /// The socket closed before the final commit's answer.
        case disconnected
        case timedOut
    }

    /// 100 ms of 16 kHz mono PCM16, the size the live send loop uses.
    package static let chunkBytes = 3_200

    private let makeClient: @Sendable () -> any RealtimeClient
    private let clock: SessionClock

    package init(makeClient: @escaping @Sendable () -> any RealtimeClient, clock: SessionClock = .live) {
        self.makeClient = makeClient
        self.clock = clock
    }

    /// How long a file may take: the connect, then the audio's own length
    /// again, which a backend that keeps up with live dictation never needs.
    package static func timeout(forPCM16Bytes bytes: Int) -> Duration {
        .seconds(30 + bytes / AudioChunkBuffer.bytesPerSecond)
    }

    /// The final transcript, or the streamed text when the backend sent no
    /// final one. Empty when nothing was said. `contextBudget` is the
    /// server's, nil for speechd and Mistral: the memo goes through one
    /// session then.
    package func transcribe(
        pcm16: Data,
        configuration: RealtimeSessionConfiguration,
        contextBudget: RealtimeContextBudget? = nil
    ) async throws -> String {
        let segments = Self.segments(ofPCM16: pcm16, budget: contextBudget)
        if segments.count > 1 {
            Log.backends.notice(
                "voice memo: \(pcm16.count / AudioChunkBuffer.bytesPerSecond, privacy: .public)s of audio in \(segments.count, privacy: .public) sessions under max_model_len \(contextBudget?.maxModelLen ?? 0, privacy: .public)"
            )
        }
        var texts: [String] = []
        for segment in segments {
            let text = try await transcribeSession(pcm16: pcm16.subdata(in: segment), configuration: configuration)
            if !text.isEmpty { texts.append(text) }
        }
        return texts.joined(separator: " ")
    }

    /// Where the memo is cut so no session takes more than `budget` allows:
    /// each cut sits in the middle of the quietest `pauseQuietSeconds` between
    /// the budget's pause window and its margin, the latest of equally quiet
    /// ones, on a chunk boundary. A memo with no quiet there is cut mid-word.
    package static func segments(ofPCM16 pcm16: Data, budget: RealtimeContextBudget?) -> [Range<Int>] {
        guard let budget, pcm16.count > budget.forceBytes else { return [0 ..< pcm16.count] }
        // Loudness of each chunk: the sum of its samples' magnitudes.
        let loudness: [Int] = pcm16.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: chunkBytes).map { start in
                let end = min(start + chunkBytes, raw.count) & ~1
                var sum = 0
                for offset in stride(from: start, to: end, by: 2) {
                    sum += abs(Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))))
                }
                return sum
            }
        }
        let quietChunks = max(1, Int(RealtimeContextBudget.pauseQuietSeconds * Double(AudioChunkBuffer.bytesPerSecond)) / chunkBytes)
        let earliest = max(1, budget.pauseWindowBytes / chunkBytes)
        let latest = max(earliest, budget.forceBytes / chunkBytes)
        var ranges: [Range<Int>] = []
        var start = 0
        while pcm16.count - start * chunkBytes > budget.forceBytes {
            var cut = start + latest
            var quietest = Int.max
            for candidate in (start + earliest) ... (start + latest) {
                let from = max(start, candidate - quietChunks / 2)
                let to = min(loudness.count, from + quietChunks)
                let sum = loudness[from ..< to].reduce(0, +)
                if sum <= quietest {
                    quietest = sum
                    cut = candidate
                }
            }
            ranges.append(start * chunkBytes ..< cut * chunkBytes)
            start = cut
        }
        ranges.append(start * chunkBytes ..< pcm16.count)
        return ranges
    }

    private func transcribeSession(pcm16: Data, configuration: RealtimeSessionConfiguration) async throws -> String {
        let client = makeClient()
        let (events, continuation) = AsyncStream<RealtimeEvent>.makeStream()
        client.setEventHandler { event, _ in continuation.yield(event) }
        do {
            try client.connect(configuration: configuration)
        } catch {
            continuation.finish()
            throw Failure.connectFailed(error.localizedDescription)
        }
        defer {
            client.disconnect()
            continuation.finish()
        }

        let chunks = stride(from: 0, to: pcm16.count, by: Self.chunkBytes).map {
            pcm16.subdata(in: $0 ..< min($0 + Self.chunkBytes, pcm16.count))
        }
        let clock = clock
        let timeout = Self.timeout(forPCM16Bytes: pcm16.count)
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                var finals: [String] = []
                var partials = ""
                var sent = false
                for await event in events {
                    switch event {
                    case .connected:
                        // Once: a socket a rollover opens connects too (#1139).
                        guard !sent else { break }
                        sent = true
                        // The client holds these until the session is ready.
                        chunks.forEach(client.sendAudioChunk)
                        client.sendCommit(final: true)
                    case .partialTranscript(let delta):
                        partials += delta
                    case .finalTranscript(let text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { finals.append(trimmed) }
                    case .transcriptionFinalized:
                        let text = finals.isEmpty ? partials : finals.joined(separator: " ")
                        return text.trimmingCharacters(in: .whitespacesAndNewlines)
                    case .error(let message), .transcriptionStopped(let message):
                        throw Failure.backend(message)
                    case .disconnected:
                        throw Failure.disconnected
                    case .status, .sessionRolledOver:
                        break
                    }
                }
                throw Failure.disconnected
            }
            group.addTask {
                await clock.sleep(timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let text = try await group.next() ?? nil else { throw Failure.timedOut }
            return text
        }
    }
}
