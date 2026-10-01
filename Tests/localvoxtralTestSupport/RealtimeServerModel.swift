import Foundation
import Synchronization

/// What speechd and vLLM answer to the realtime client's appends and commits
/// (#1070), for tests that hand the real client's frames to it and its
/// answers back to the client. The audio a test sends is UTF-8: the model
/// hears each chunk as one word. Answers wait in `takeSent()` until the test
/// delivers them, so a test decides which client frames cross them.
package final class RealtimeServerModel: @unchecked Sendable {
    package enum Kind: Sendable {
        /// The bundled helper (`RealtimeSpeechServer`): a non-final commit
        /// does nothing, and each final commit is answered with one `done`
        /// carrying every word heard since the previous one.
        case speechd
        /// vLLM's `/v1/realtime` (`connection.py`): a non-final commit starts
        /// a run unless one is running. The run reads the queued audio until
        /// the end-of-audio marker a final commit queues, or until
        /// `limitChunks` chunks (its context limit); then it sends `done` and
        /// empties the queue. A final commit starts no run.
        case vllm(limitChunks: Int?)
    }

    private enum Queued {
        case audio(String)
        case endOfAudio
    }

    private struct State {
        var queue: [Queued] = []
        /// The words of the vLLM run in progress; nil when none runs.
        var run: [String]?
        var heard: [String] = []
        var sent: [[String: Any]] = []
    }

    private let kind: Kind
    private let state = Mutex(State())

    package init(_ kind: Kind) {
        self.kind = kind
    }

    /// One frame the client transmitted. Anything that is not a JSON event
    /// (a test's placeholder frame) is ignored.
    package func receive(_ text: String) {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return
        }
        state.withLock { s in
            switch json["type"] as? String {
            case "input_audio_buffer.append":
                let word = (json["audio"] as? String)
                    .flatMap { Data(base64Encoded: $0) }
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                appendLocked(&s, word)
            case "input_audio_buffer.commit":
                commitLocked(&s, final: json["final"] as? Bool == true)
            default:
                break
            }
        }
    }

    /// The frames sent since the last call, oldest first.
    package func takeSent() -> [[String: Any]] {
        state.withLock { s in
            defer { s.sent = [] }
            return s.sent
        }
    }

    private func appendLocked(_ s: inout State, _ word: String) {
        switch kind {
        case .speechd:
            s.heard.append(word)
        case .vllm:
            s.queue.append(.audio(word))
            readQueueLocked(&s)
        }
    }

    private func commitLocked(_ s: inout State, final: Bool) {
        switch kind {
        case .speechd:
            guard final else { return }
            sendDoneLocked(&s, s.heard)
            s.heard = []
        case .vllm:
            if final {
                s.queue.append(.endOfAudio)
            } else if s.run == nil {
                s.run = []
            }
            readQueueLocked(&s)
        }
    }

    private func readQueueLocked(_ s: inout State) {
        guard case .vllm(let limitChunks) = kind else { return }
        while var run = s.run, !s.queue.isEmpty {
            let item = s.queue.removeFirst()
            switch item {
            case .audio(let word):
                run.append(word)
                s.run = run
                if let limitChunks, run.count >= limitChunks {
                    endRunLocked(&s)
                }
            case .endOfAudio:
                endRunLocked(&s)
            }
        }
    }

    private func endRunLocked(_ s: inout State) {
        sendDoneLocked(&s, s.run ?? [])
        s.run = nil
        s.queue = []
    }

    private func sendDoneLocked(_ s: inout State, _ words: [String]) {
        s.sent.append(["type": "transcription.done", "text": words.joined(separator: " ")])
    }
}
