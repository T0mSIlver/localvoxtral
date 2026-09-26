import Foundation
import Synchronization
@testable import localvoxtral

/// A batch transcriber that opens no connection: it keeps every request and
/// answers from `reply`, or, held, answers nothing until its task is
/// cancelled.
final class FakeBatchTranscriber: MistralBatchTranscribing, @unchecked Sendable {
    struct Call: Equatable {
        let wav: Data
        let language: String?
        let contextBias: [String]
        let apiKey: String
        let endpoint: URL
    }

    enum Reply {
        case text(String)
        case failure(any Error)
        /// Never answers; returns only when cancelled.
        case held
    }

    private struct State {
        var calls: [Call] = []
        var cancelled = 0
        var held: CheckedContinuation<Void, Never>?
    }

    private let reply: Reply
    private let state = Mutex(State())
    let called = BoundedWait()

    init(_ reply: Reply) {
        self.reply = reply
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var cancelledCount: Int { state.withLock { $0.cancelled } }

    func transcribe(
        wav: Data,
        language: String?,
        contextBias: [String],
        apiKey: String,
        endpoint: URL
    ) async throws -> MistralBatchTranscription.Result {
        state.withLock {
            $0.calls.append(Call(
                wav: wav, language: language, contextBias: contextBias,
                apiKey: apiKey, endpoint: endpoint))
        }
        called.resolve()
        switch reply {
        case .text(let text):
            return MistralBatchTranscription.Result(text: text)
        case .failure(let error):
            throw error
        case .held:
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let cancelled = state.withLock { s -> Bool in
                        if s.cancelled > 0 { return true }
                        s.held = continuation
                        return false
                    }
                    if cancelled { continuation.resume() }
                }
            } onCancel: {
                let held = state.withLock { s -> CheckedContinuation<Void, Never>? in
                    s.cancelled += 1
                    defer { s.held = nil }
                    return s.held
                }
                held?.resume()
            }
            throw CancellationError()
        }
    }
}
