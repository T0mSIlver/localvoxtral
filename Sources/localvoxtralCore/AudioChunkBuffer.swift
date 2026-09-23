import Foundation
import Synchronization

package final class AudioChunkBuffer: Sendable {
    /// 16 kHz mono PCM16 — the format `MicrophoneCaptureService` converts to.
    package static let bytesPerSecond = 32_000

    /// Longest stretch of undrained audio the buffer keeps. The send loop
    /// drains every `TimingConstants.audioSendInterval`, so this only bites
    /// while nothing is draining: a reconnect gap (#380), or a stalled send
    /// task. Past it the OLDEST audio is dropped — what is still worth
    /// transcribing is the speech closest to now. Sized above the worst case
    /// a `RealtimeReconnectPolicy` run can take, so a reconnect that lands
    /// within its retry cap replays the whole gap.
    package static let maxRetainedSeconds = 20

    package static let defaultMaxRetainedBytes = bytesPerSecond * maxRetainedSeconds

    private let buffer = Mutex(Data())
    private let maxRetainedBytes: Int

    package init(maxRetainedBytes: Int = AudioChunkBuffer.defaultMaxRetainedBytes) {
        // Even, so trimming can never land mid-sample and shift every
        // following PCM16 frame by a byte.
        self.maxRetainedBytes = max(2, maxRetainedBytes - maxRetainedBytes % 2)
    }

    package func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.withLock {
            $0.append(chunk)
            guard $0.count > maxRetainedBytes else { return }
            $0 = Data($0.suffix(maxRetainedBytes))
        }
    }

    package func takeAll() -> Data {
        buffer.withLock {
            let output = $0
            $0.removeAll(keepingCapacity: true)
            return output
        }
    }

    /// Bytes held right now. Read by the reconnect path to log how much of the
    /// gap it is about to replay.
    package var bufferedByteCount: Int {
        buffer.withLock { $0.count }
    }

    package func clear() {
        buffer.withLock { $0.removeAll(keepingCapacity: true) }
    }
}
