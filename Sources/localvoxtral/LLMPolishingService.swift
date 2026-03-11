import Foundation
import os

// Test seams need to substitute a suspending polishing service so stop cleanup
// can be proven idempotent while post-processing is still in flight.
protocol LLMPolishingServicing: Sendable {
    func polish(
        text: String,
        configuration: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult
}

struct LLMPolishingConfiguration: Sendable {
    let endpointURL: URL
    let apiKey: String
    let model: String
}

struct LLMPolishingResult: Sendable {
    let rawText: String
    let polishedText: String
    let durationSeconds: Double
}

enum LLMPolishingError: Error, LocalizedError, Sendable {
    case emptyInput
    case requestFailed(statusCode: Int, body: String)
    case invalidResponse
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "No text to polish."
        case .requestFailed(let statusCode, let body):
            return "LLM request failed (HTTP \(statusCode)): \(body)"
        case .invalidResponse:
            return "LLM returned an invalid or empty response."
        case .networkError(let message):
            return "LLM network error: \(message)"
        }
    }
}

struct LLMPolishingService: LLMPolishingServicing {
    private static let systemPrompt =
        "Clean up grammar, punctuation, capitalization. Preserve intent. Return only corrected text."

    private static let timeoutInterval: TimeInterval = 15

    func polish(
        text: String,
        configuration: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMPolishingError.emptyInput
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        var request = URLRequest(url: configuration.endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = Self.timeoutInterval

        let body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": trimmed],
            ],
            "temperature": 0.3,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMPolishingError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMPolishingError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw LLMPolishingError.requestFailed(
                statusCode: httpResponse.statusCode,
                body: String(responseBody.prefix(500))
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw LLMPolishingError.invalidResponse
        }

        let polished = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !polished.isEmpty else {
            throw LLMPolishingError.invalidResponse
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime

        return LLMPolishingResult(
            rawText: trimmed,
            polishedText: polished,
            durationSeconds: duration
        )
    }
}
