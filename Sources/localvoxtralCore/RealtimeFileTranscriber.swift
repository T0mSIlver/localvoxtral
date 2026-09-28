import Foundation
import Synchronization

/// Recorded audio through a streaming realtime socket, as fast as the backend
/// takes it (#925). Every chunk is queued at once and then one final commit,
/// so the bundled helper batches the backlog into larger steps and finishes
/// well ahead of real time. No batch model is involved.
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
    /// final one. Empty when nothing was said.
    package func transcribe(pcm16: Data, configuration: RealtimeSessionConfiguration) async throws -> String {
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
                for await event in events {
                    switch event {
                    case .connected:
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
                    case .status:
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
