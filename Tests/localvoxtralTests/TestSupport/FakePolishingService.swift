import Foundation
@testable import localvoxtral

/// Answers every polish from `reply` without networking, and keeps the
/// requests the session built. The default returns the input unchanged.
actor FakePolishingService: LLMPolishingServicing {
    typealias Reply = @Sendable (LLMPolishingRequest) throws -> String

    private let reply: Reply
    private let durationSeconds: TimeInterval
    private(set) var requests: [LLMPolishingRequest] = []

    var lastRequest: LLMPolishingRequest? { requests.last }

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
        configuration _: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        requests.append(request)
        return LLMPolishingResult(
            rawText: request.inputText,
            polishedText: try reply(request),
            durationSeconds: durationSeconds
        )
    }
}
