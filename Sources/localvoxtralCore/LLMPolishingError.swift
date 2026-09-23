import Foundation

package enum LLMPolishingError: Error, LocalizedError, Sendable {
    case emptyInput
    case requestFailed(statusCode: Int, body: String)
    case invalidResponse
    case networkError(String)
    /// The endpoint accepted the connection but did not answer within the request
    /// timeout. Distinct from `networkError` so a slow polish (a long transcript, a cold
    /// prefix cache) never reads as "unable to connect" (#314).
    case timedOut(afterSeconds: TimeInterval)

    package var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "No text to polish."
        case .requestFailed(let statusCode, let body):
            return "LLM request failed (HTTP \(statusCode)): \(body)"
        case .invalidResponse:
            return "LLM returned an invalid or empty response."
        case .networkError(let message):
            return "LLM network error: \(message)"
        case .timedOut(let seconds):
            return "LLM request timed out after \(Int(seconds.rounded())) s."
        }
    }
}
