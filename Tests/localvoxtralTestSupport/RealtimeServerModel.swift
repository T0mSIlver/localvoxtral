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
/// - `.llamaServer` follows llama.cpp's `ws_realtime`
///   (`tools/server/server-context.cpp`, after ggml-org/llama.cpp#30994):
///   audio is transcribed as it arrives, with or without a commit. A
///   non-final commit answers `input_audio_buffer.committed` at once and,
///   once its audio is decoded, a `completed` for that item alone; then a
///   new item opens. A final commit ends the input, and the last item's
///   `completed` comes when the stream drains. While `holdDrains` is set,
///   every `completed` waits for `drain()`: the decoder is still behind.
///
/// The `done` text names the audio it covers, as "<n> bytes".
package final class RealtimeServerModel: @unchecked Sendable {
    package enum Kind: Sendable {
        case vllm
        case speechd
        case llamaServer
    }

    /// The `session.created` this server opens a socket with.
    package static func sessionCreated(_ kind: Kind) -> [String: Any] {
        switch kind {
        case .vllm, .speechd:
            return ["type": "session.created"]
        case .llamaServer:
            return [
                "type": "session.created",
                "session": [
                    "id": "sess_test",
                    "object": "realtime.transcription_session",
                    "type": "transcription",
                    "audio": ["input": ["format": ["type": "audio/pcm", "rate": 16_000]]],
                ] as [String: Any],
            ]
        }
    }

    /// llama-server's `completed` for one item.
    package static func llamaCompleted(_ text: String) -> [String: Any] {
        [
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "item_test",
            "content_index": 0,
            "transcript": text,
        ]
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
    private var holdsDrains = false
    private var heldCompletions: [[String: Any]] = []

    package init(_ kind: Kind) {
        self.kind = kind
    }

    /// From now on every llama-server `completed` waits for `drain()`.
    package func holdDrains() {
        lock.lock()
        holdsDrains = true
        lock.unlock()
    }

    /// llama-server only: the decoder catches up and sends the `completed`
    /// frames it held, in order.
    package func drain() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        holdsDrains = false
        defer { heldCompletions.removeAll() }
        return heldCompletions
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
            if kind == .llamaServer {
                runBytes += bytes
                return []
            }
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
            case .llamaServer:
                let completed = Self.llamaCompleted("\(runBytes) bytes")
                runBytes = 0
                var frames: [[String: Any]] = final ? [] : [["type": "input_audio_buffer.committed"]]
                if holdsDrains {
                    heldCompletions.append(completed)
                } else {
                    frames.append(completed)
                }
                return frames
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
