import Foundation

/// How a realtime server answers the client's commits, without a socket
/// (#1135). Feed it every frame the client hands its socket; it returns the
/// frames the server would send back, for the test to hand the client.
///
/// - `.vllm` follows `vllm/entrypoints/speech_to_text/realtime/connection.py`:
///   a non-final commit starts a run when none is going; a final commit only
///   queues the end-of-audio mark and starts nothing. A run reads the queue
///   and sends one `transcription.done` when it reaches the mark. A run cut
///   at its limit (`endRunAtLimit()`) sends its `done` and empties the queue.
/// - `.speechd` follows `SpeechHelper`'s `RealtimeSpeechServer`: a non-final
///   commit is a no-op; a final commit answers with a `done` for everything
///   appended since the last one.
///
/// The `done` text names the audio it covers, as "<n> bytes".
package final class RealtimeServerModel: @unchecked Sendable {
    package enum Kind: Sendable {
        case vllm
        case speechd
    }

    private enum Item {
        case audio(Int)
        case end
    }

    private let kind: Kind
    private let lock = NSLock()
    private var queue: [Item] = []
    private var isRunning = false
    private var runBytes = 0

    package init(_ kind: Kind) {
        self.kind = kind
    }

    /// Whether a run is going: the server is reading audio it will answer.
    package var hasRunGoing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    /// The server's answer to one client frame, in order. Frames that are not
    /// JSON (a test's placeholder) are ignored.
    package func receive(_ text: String) -> [[String: Any]] {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return []
        }
        lock.lock()
        defer { lock.unlock() }
        switch json["type"] as? String {
        case "input_audio_buffer.append":
            let bytes = (json["audio"] as? String).flatMap { Data(base64Encoded: $0) }?.count ?? 0
            queue.append(.audio(bytes))
        case "input_audio_buffer.commit":
            let final = json["final"] as? Bool ?? false
            switch kind {
            case .vllm:
                if final {
                    queue.append(.end)
                } else if !isRunning {
                    isRunning = true
                    runBytes = 0
                }
            case .speechd:
                guard final else { return [] }
                queue.append(.end)
                isRunning = true
                runBytes = 0
            }
        default:
            return []
        }
        return drainLocked()
    }

    /// vLLM only: the run reaches its limit, sends its `done` and drops the
    /// audio it had not read yet.
    package func endRunAtLimit() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return [] }
        let done = doneLocked()
        queue.removeAll()
        return [done]
    }

    private func drainLocked() -> [[String: Any]] {
        guard isRunning else { return [] }
        var frames: [[String: Any]] = []
        while !queue.isEmpty {
            switch queue.removeFirst() {
            case .audio(let bytes):
                runBytes += bytes
            case .end:
                frames.append(doneLocked())
                return frames
            }
        }
        return frames
    }

    private func doneLocked() -> [String: Any] {
        isRunning = false
        let text = "\(runBytes) bytes"
        runBytes = 0
        return ["type": "transcription.done", "text": text]
    }
}
