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
    /// Optional generation cap forwarded as `max_tokens`. Production polish
    /// requests leave it nil (the helper applies its own default); the
    /// prompt-prefix warmup sets 1 so the throwaway generation costs a
    /// single token.
    let maxTokens: Int?

    init(
        inputText: String,
        systemPrompt: String,
        userPrompts: [String],
        maxTokens: Int? = nil
    ) {
        self.inputText = inputText
        self.systemPrompt = systemPrompt
        self.userPrompts = userPrompts
        self.maxTokens = maxTokens
    }
}

struct LLMPolishingConfiguration: Sendable {
    let endpointURL: URL
    let apiKey: String
    let model: String
    let samplingDefaults: PolishSamplingDefaults?
    let chatTemplateArguments: [String: Bool]?
    /// llama.cpp per-request reasoning cap. Nil preserves the normal OpenAI
    /// request shape; zero disables reasoning when the server supports it.
    let thinkingBudgetTokens: Int?
    /// Bifrost drops provider-specific body fields unless this opt-in header
    /// is present. Other OpenAI-compatible servers harmlessly ignore it.
    let passthroughExtraParameters: Bool

    init(
        endpointURL: URL,
        apiKey: String,
        model: String,
        samplingDefaults: PolishSamplingDefaults? = nil,
        chatTemplateArguments: [String: Bool]? = nil,
        thinkingBudgetTokens: Int? = nil,
        passthroughExtraParameters: Bool = false
    ) {
        self.endpointURL = endpointURL
        self.apiKey = apiKey
        self.model = model
        self.samplingDefaults = samplingDefaults
        self.chatTemplateArguments = chatTemplateArguments
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.passthroughExtraParameters = passthroughExtraParameters
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
    /// Polish request timeout. Sized for the managed worst case, not the warm
    /// path: a 4B model whose polishd prefix-cache checkpoint was invalidated
    /// re-prefills ~2.3k tokens before generating — a real request took 23.6 s
    /// and the previous 15 s timeout abandoned it (field, 2026-07-11). Polish
    /// is async behind the overlay: a slow polish beats a discarded one.
    static let requestTimeoutInterval: TimeInterval = 40

    func polish(
        request: LLMPolishingRequest,
        configuration: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        let trimmed = request.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMPolishingError.emptyInput
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        let urlRequest = try Self.makeURLRequest(
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

    /// Maps a user-entered polishing endpoint to the effective OpenAI-compatible
    /// `chat/completions` URL, so the Settings field accepts a bare base URL
    /// (the convention every OpenAI-compatible client follows) while remaining
    /// backward compatible with the full `/v1/chat/completions` URLs users used
    /// to have to type.
    ///
    /// The path is inspected case-insensitively; the scheme, host, port, and
    /// query are never altered — only the path is rewritten, so the Local
    /// Network preflight (which classifies by host/port) sees the same target.
    /// Rules:
    /// - A path already ending in `/chat/completions` (with or without a
    ///   trailing slash) is returned exactly as given. llama.cpp, vLLM, LM
    ///   Studio, and Ollama's OpenAI-compat surface all expose
    ///   `/v1/chat/completions`, so any full URL round-trips unchanged.
    /// - An empty path or `/` (the base-URL case) gets `/v1/chat/completions`
    ///   appended: `http://127.0.0.1:8080` → `http://127.0.0.1:8080/v1/chat/completions`.
    /// - A path ending in `/v1` (or `/v1/`) gets `/chat/completions` appended.
    ///   This also covers proxy prefixes that still mount the OpenAI API under
    ///   `/v1` (`/proxy/v1` → `/proxy/v1/chat/completions`).
    /// - Any other non-empty path is treated as a base and gets
    ///   `/v1/chat/completions` appended, since that is where every server above
    ///   mounts the OpenAI API.
    ///
    /// Appending never introduces a new double slash (a `//` already inside the
    /// input path is preserved as typed). Query and fragment are preserved. If
    /// the input cannot be broken into URL components it is returned unchanged,
    /// so the existing failure handling (an invalid endpoint yields a nil
    /// configuration and no request) still applies.
    static func normalizedChatCompletionsURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }

        // Trailing slashes are insignificant for the decision; collapse them to
        // a single canonical path before matching so `/v1/` and `/v1` behave
        // alike and appended segments never produce `//`.
        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        let lowered = path.lowercased()

        if lowered.hasSuffix("/chat/completions") {
            // Already a full chat/completions URL — leave the user's input
            // exactly as typed (including any trailing slash).
            return url
        }

        let effectivePath: String
        if path.isEmpty || path == "/" {
            effectivePath = "/v1/chat/completions"
        } else if lowered.hasSuffix("/v1") {
            effectivePath = path + "/chat/completions"
        } else {
            effectivePath = path + "/v1/chat/completions"
        }

        components.path = effectivePath
        return components.url ?? url
    }

    /// The full URLRequest for one polish call — the single construction path
    /// (and the test seam pinning the timeout without networking).
    static func makeURLRequest(
        request: LLMPolishingRequest,
        configuration: LLMPolishingConfiguration
    ) throws -> URLRequest {
        var urlRequest = URLRequest(
            url: normalizedChatCompletionsURL(configuration.endpointURL)
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if configuration.passthroughExtraParameters {
            urlRequest.setValue("true", forHTTPHeaderField: "x-bf-passthrough-extra-params")
        }
        urlRequest.timeoutInterval = Self.requestTimeoutInterval
        urlRequest.httpBody = try requestBody(
            request: request,
            configuration: configuration
        )
        return urlRequest
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
        if let maxTokens = request.maxTokens {
            body["max_tokens"] = maxTokens
        }
        if let chatTemplateArguments = configuration.chatTemplateArguments {
            body["chat_template_kwargs"] = chatTemplateArguments
        }
        if let thinkingBudgetTokens = configuration.thinkingBudgetTokens {
            body["thinking_budget_tokens"] = thinkingBudgetTokens
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
}
