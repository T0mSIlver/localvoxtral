import Foundation
@testable import localvoxtral

/// Holds every polish request open until the test resumes it, so a test can
/// act while a commit is demonstrably in flight. Answers "Hello world.".
actor BlockingMockLLMPolishingService: LLMPolishingServicing {
    private var requests = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func polish(
        request: LLMPolishingRequest,
        configuration _: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        requests += 1
        for waiter in arrivalWaiters {
            waiter.resume()
        }
        arrivalWaiters.removeAll()
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return LLMPolishingResult(
            rawText: request.inputText,
            polishedText: "Hello world.",
            durationSeconds: 0.01
        )
    }

    func callCount() -> Int {
        requests
    }

    func resumePendingRequest() {
        continuation?.resume()
        continuation = nil
    }

    /// Returns once the commit has reached this service, so a test can assert
    /// on a deliberately in-flight commit without a wall-clock poll. Returns
    /// straight away if the request already arrived — on an actor, the count
    /// and the waiter list cannot disagree.
    func waitUntilFirstRequestArrives() async {
        guard requests == 0 else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }
}
