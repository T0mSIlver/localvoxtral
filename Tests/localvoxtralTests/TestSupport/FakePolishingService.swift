import Foundation
@testable import localvoxtral

/// Answers every polish from `reply` without networking, and keeps the
/// requests the session built together with the configuration each one was
/// sent with. The default returns the input unchanged.
actor FakePolishingService: LLMPolishingServicing {
    typealias Reply = @Sendable (LLMPolishingRequest) throws -> String

    private let reply: Reply
    private let durationSeconds: TimeInterval
    private(set) var requests: [LLMPolishingRequest] = []
    private(set) var configurations: [LLMPolishingConfiguration] = []
    private var holdsNextRequest = false
    private var heldRequest: CheckedContinuation<Void, Never>?
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var lastRequest: LLMPolishingRequest? { requests.last }
    var lastConfiguration: LLMPolishingConfiguration? { configurations.last }

    init(durationSeconds: TimeInterval = 0.01, reply: @escaping Reply = { $0.inputText }) {
        self.reply = reply
        self.durationSeconds = durationSeconds
    }

    init(returning text: String, durationSeconds: TimeInterval = 0.01) {
        self.init(durationSeconds: durationSeconds) { _ in text }
    }

    init(transform: @escaping @Sendable (String) -> String) {
        self.init { transform($0.inputText) }
    }

    init(failing error: any Error) {
        self.init { _ in throw error }
    }

    func polish(
        request: LLMPolishingRequest,
        configuration: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        requests.append(request)
        configurations.append(configuration)
        let reached = countWaiters.filter { $0.count <= requests.count }
        countWaiters.removeAll { $0.count <= requests.count }
        reached.forEach { $0.continuation.resume() }
        if holdsNextRequest {
            holdsNextRequest = false
            await withCheckedContinuation { heldRequest = $0 }
        }
        return LLMPolishingResult(
            rawText: request.inputText,
            polishedText: try reply(request),
            durationSeconds: durationSeconds
        )
    }

    /// The next request waits for `releaseHeldRequest()` before it answers,
    /// so a test can act while it is in flight.
    func holdNextRequest() {
        holdsNextRequest = true
    }

    func releaseHeldRequest() {
        heldRequest?.resume()
        heldRequest = nil
    }

    /// Returns once `count` requests have arrived; at once if they already have.
    func waitForRequests(_ count: Int) async {
        guard requests.count < count else { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }
}
