import Foundation
import Synchronization
import localvoxtralCore

/// A batch transcriber that opens no connection: it keeps every request and
/// answers from `reply`, or, held, answers nothing until its task is
/// cancelled.
package final class FakeBatchTranscriber: MistralBatchTranscribing, @unchecked Sendable {
    package struct Call: Equatable {
        package let wav: Data
        package let language: String?
        package let contextBias: [String]
        package let apiKey: String
        package let endpoint: URL

        package init(wav: Data, language: String?, contextBias: [String], apiKey: String, endpoint: URL) {
            self.wav = wav
            self.language = language
            self.contextBias = contextBias
            self.apiKey = apiKey
            self.endpoint = endpoint
        }
    }

    package enum Reply {
        case text(String)
        case failure(any Error)
        /// Never answers; returns only when cancelled.
        case held
    }

    private struct State {
        package var calls: [Call] = []
        var cancelled = 0
        var held: CheckedContinuation<Void, Never>?
    }

    private let reply: Reply
    private let state = Mutex(State())
    package let called = BoundedWait()

    package init(_ reply: Reply) {
        self.reply = reply
    }

    package var calls: [Call] { state.withLock { $0.calls } }
    package var cancelledCount: Int { state.withLock { $0.cancelled } }

    package func transcribe(
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
