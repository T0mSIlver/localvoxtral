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

    /// `errorDescription` without the response body, which can quote the
    /// request and so the dictated text: the part safe to log public.
    package var publicLogDescription: String {
        if case .requestFailed(let statusCode, _) = self { return "LLM request failed (HTTP \(statusCode))." }
        return errorDescription ?? "LLM error."
    }

    /// Any polish error's public part: an `LLMPolishingError` without its
    /// body, anything else by its description.
    package static func publicLogDescription(of error: any Error) -> String {
        (error as? LLMPolishingError)?.publicLogDescription ?? error.localizedDescription
    }
}
