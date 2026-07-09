import Foundation
import os

// Test seams need to substitute a suspending polishing service so stop cleanup
// can be proven idempotent while post-processing is still in flight.
protocol LLMPolishingServicing: Sendable {
    func polish(
        request: LLMPolishingRequest,
        configuration: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult
}

struct LLMPolishingRequest: Sendable {
    let inputText: String
    let systemPrompt: String
    let userPrompts: [String]
}

struct LLMPolishingConfiguration: Sendable {
    let endpointURL: URL
    let apiKey: String
    let model: String
    let samplingDefaults: PolishSamplingDefaults?

    init(
        endpointURL: URL,
        apiKey: String,
        model: String,
        samplingDefaults: PolishSamplingDefaults? = nil
    ) {
        self.endpointURL = endpointURL
        self.apiKey = apiKey
        self.model = model
        self.samplingDefaults = samplingDefaults
    }
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
    private static let timeoutInterval: TimeInterval = 15

    func polish(
        request: LLMPolishingRequest,
        configuration: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        let trimmed = request.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMPolishingError.emptyInput
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        var urlRequest = URLRequest(url: configuration.endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.timeoutInterval = Self.timeoutInterval

        urlRequest.httpBody = try Self.requestBody(
            request: request,
            configuration: configuration
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
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

    static func requestBody(
        request: LLMPolishingRequest,
        configuration: LLMPolishingConfiguration
    ) throws -> Data {
        let messages = [["role": "system", "content": request.systemPrompt]]
            + request.userPrompts.map { ["role": "user", "content": $0] }
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": messages,
            "temperature": 0.3,
        ]
        if let defaults = configuration.samplingDefaults {
            if let temperature = defaults.temperature {
                body["temperature"] = temperature
            }
            if let topP = defaults.topP {
                body["top_p"] = topP
            }
            if let topK = defaults.topK {
                body["top_k"] = topK
            }
            if let minP = defaults.minP {
                body["min_p"] = minP
            }
            if let presencePenalty = defaults.presencePenalty {
                body["presence_penalty"] = presencePenalty
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
}
