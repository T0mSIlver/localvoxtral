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
    /// Nil for a polish, which the user is waiting on. The term-suggestion
    /// request reads weeks of dictations in one go and is started from
    /// Settings, so it may take longer than a polish is allowed to.
    let timeoutSeconds: TimeInterval?
    /// False for a polish, which has to be fast. True asks a hosted reasoning
    /// model to think before answering (`MistralReasoningEffort.high`);
    /// self-hosted shapes ignore it and keep their configured behaviour.
    let prefersDeepReasoning: Bool

    init(
        inputText: String,
        systemPrompt: String,
        userPrompts: [String],
        maxTokens: Int? = nil,
        timeoutSeconds: TimeInterval? = nil,
        prefersDeepReasoning: Bool = false
    ) {
        self.inputText = inputText
        self.systemPrompt = systemPrompt
        self.userPrompts = userPrompts
        self.maxTokens = maxTokens
        self.timeoutSeconds = timeoutSeconds
        self.prefersDeepReasoning = prefersDeepReasoning
    }
}

/// Which wire dialect one polish request is serialized in. The app talks to
/// self-hosted OpenAI-compatible servers (llama.cpp, mlx-lm, vLLM, the bundled
/// polishd) AND to Mistral's hosted API, and the two do not accept the same
/// body.
enum LLMPolishingRequestShape: String, Sendable {
    /// Every self-hosted OpenAI-compatible server. Emits the union of fields
    /// those servers understand — including the llama.cpp / mlx-lm / Bifrost
    /// extras (`top_k`, `min_p`, `chat_template_kwargs`,
    /// `thinking_budget_tokens`, the `x-bf-passthrough-extra-params` header),
    /// which a server that does not know them ignores.
    case openAICompatible

    /// Mistral's hosted `/v1/chat/completions`. Its `ChatCompletionRequest`
    /// schema is closed: it rejects unknown body fields, so this shape emits
    /// ONLY `model`, `messages`, `temperature`, `top_p`, `presence_penalty`,
    /// `max_tokens` and `reasoning_effort` — never `top_k`, `min_p`,
    /// `chat_template_kwargs` or `thinking_budget_tokens`, and never the
    /// `x-bf-passthrough-extra-params` header, even when the configuration
    /// carries them (a catalog model's sampling defaults do). Those four are
    /// llama.cpp / mlx-lm / Bifrost extras with no Mistral equivalent.
    ///
    /// `reasoning_effort` asks for the least reasoning the model takes
    /// (`MistralReasoningEffort`): polishing must never pay a reasoning
    /// trace's latency or output tokens to insert one space before a question
    /// mark, and a value the model does not take is a 400.
    case mistral
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
    /// The wire dialect this configuration's requests are serialized in.
    let requestShape: LLMPolishingRequestShape
    /// Mistral shape only. Nil derives it from the model id alone
    /// (`MistralReasoningEffort.forModel`), which is right for every
    /// reasoning model; Settings passes the catalog's answer so a model
    /// without reasoning gets no field at all.
    let mistralReasoningEffort: MistralReasoningEffort?

    init(
        endpointURL: URL,
        apiKey: String,
        model: String,
        samplingDefaults: PolishSamplingDefaults? = nil,
        chatTemplateArguments: [String: Bool]? = nil,
        thinkingBudgetTokens: Int? = nil,
        passthroughExtraParameters: Bool = false,
        requestShape: LLMPolishingRequestShape = .openAICompatible,
        mistralReasoningEffort: MistralReasoningEffort? = nil
    ) {
        self.endpointURL = endpointURL
        self.apiKey = apiKey
        self.model = model
        self.samplingDefaults = samplingDefaults
        self.chatTemplateArguments = chatTemplateArguments
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.passthroughExtraParameters = passthroughExtraParameters
        self.requestShape = requestShape
        self.mistralReasoningEffort = mistralReasoningEffort
    }
}

/// Endpoint and model for Mistral's hosted polishing API. Settings wires these
/// in separately; they live here so the request shape and its defaults are
/// stated in one place.
enum MistralPolishDefaults {
    /// Base URL — `normalizedChatCompletionsURL` turns it into
    /// `https://api.mistral.ai/v1/chat/completions`.
    static let endpoint = URL(string: "https://api.mistral.ai")!
    /// `mistral-medium-3-5` (aliases `mistral-medium-latest`,
    /// `mistral-medium-3`).
    static let model = "mistral-medium-3-5"
}

struct LLMPolishingResult: Sendable {
    let rawText: String
    let polishedText: String
    let durationSeconds: Double
    var usage: LLMTokenUsage? = nil
}

/// A chat/completions response's `usage` object, plus the model that answered.
struct LLMTokenUsage: Equatable, Sendable {
    let model: String?
    let promptTokens: Int
    let cachedPromptTokens: Int
    let completionTokens: Int

    init(model: String?, promptTokens: Int, cachedPromptTokens: Int = 0, completionTokens: Int) {
        self.model = model
        self.promptTokens = promptTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.completionTokens = completionTokens
    }

    /// Nil when the response carries no `usage` with at least the prompt and
    /// completion counts.
    init?(responseObject json: [String: Any]) {
        guard let usage = json["usage"] as? [String: Any],
            let prompt = (usage["prompt_tokens"] as? NSNumber)?.intValue,
            let completion = (usage["completion_tokens"] as? NSNumber)?.intValue
        else { return nil }
        let details = usage["prompt_tokens_details"] as? [String: Any]
        self.init(
            model: (json["model"] as? String).flatMap { $0.trimmed.isEmpty ? nil : $0.trimmed },
            promptTokens: prompt,
            cachedPromptTokens: (details?["cached_tokens"] as? NSNumber)?.intValue ?? 0,
            completionTokens: completion
        )
    }
}

extension MistralUsageEntry {
    /// A polish request's entry. The answering model prices it when the
    /// response names one the price table knows, the requested model
    /// otherwise (an alias that starts answering with a newer id keeps its
    /// price); a request with no usage is counted, unpriced.
    static func polish(date: Date, requestedModel: String, usage: LLMTokenUsage?) -> Self {
        let requested = requestedModel.trimmed
        let model = usage?.model ?? requested
        guard let usage else {
            return MistralUsageEntry(date: date, kind: .polish, model: model)
        }
        let cost = { (id: String) in
            MistralPricing.polishCost(
                model: id,
                promptTokens: usage.promptTokens,
                cachedPromptTokens: usage.cachedPromptTokens,
                completionTokens: usage.completionTokens
            )
        }
        return MistralUsageEntry(
            date: date,
            kind: .polish,
            model: model,
            promptTokens: usage.promptTokens,
            cachedPromptTokens: usage.cachedPromptTokens,
            completionTokens: usage.completionTokens,
            costEUR: cost(model) ?? cost(requested)
        )
    }
}

struct LLMPolishingService: LLMPolishingServicing {
    /// Receives one entry per request sent in the Mistral shape — the only
    /// shape that reaches a billed API. Nil records nothing.
    var usageRecorder: (any MistralUsageRecording)?

    init(usageRecorder: (any MistralUsageRecording)? = nil) {
        self.usageRecorder = usageRecorder
    }

    /// The polish timeout for an empty transcript; longer transcripts get
    /// more (`PolishRequestTimeout`). Polish is async behind the overlay: a
    /// slow polish beats a discarded one.
    static let requestTimeoutInterval: TimeInterval = PolishRequestTimeout.floorSeconds

    /// One rule for every backend. The timeout is only the client's cap: a
    /// fast hosted model finishes long before it, and a long transcript takes
    /// longer on an external server or Mistral too.
    static func timeoutInterval(for request: LLMPolishingRequest) -> TimeInterval {
        PolishRequestTimeout.seconds(
            forInputCharacters: request.inputText.count,
            override: request.timeoutSeconds
        )
    }

    /// Classify a URLSession transport failure. A timeout keeps its own case; every other
    /// failure stays a network error carrying the system's description.
    static func polishingError(
        forTransportError error: Error,
        timeoutSeconds: TimeInterval
    ) -> LLMPolishingError {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .timedOut(afterSeconds: timeoutSeconds)
        }
        return .networkError(error.localizedDescription)
    }

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
            let polishingError = Self.polishingError(
                forTransportError: error,
                timeoutSeconds: urlRequest.timeoutInterval
            )
            // A request abandoned after it was sent (timed out, cancelled by
            // the next dictation, connection dropped) may still be billed, and
            // Mistral never gets to say for how much: record it as unpriced
            // rather than let it vanish. One that never left costs nothing
            // either way — it only shows in the unpriced count.
            if Self.mayHaveBeenBilled(transportError: error) {
                recordMistralUsage(configuration: configuration, usage: nil)
            }
            throw polishingError
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

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // A 2xx is billed whether or not its content is usable, so usage is
        // recorded before the content is judged.
        let usage = json.flatMap(LLMTokenUsage.init(responseObject:))
        recordMistralUsage(configuration: configuration, usage: usage)

        guard let json, let content = Self.assistantText(inResponseObject: json) else {
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
            durationSeconds: duration,
            usage: usage
        )
    }

    static func mayHaveBeenBilled(transportError error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return error is CancellationError
        }
        switch urlError.code {
        case .timedOut, .cancelled, .networkConnectionLost:
            return true
        default:
            return false
        }
    }

    private func recordMistralUsage(
        configuration: LLMPolishingConfiguration,
        usage: LLMTokenUsage?
    ) {
        guard configuration.requestShape == .mistral, let usageRecorder else { return }
        usageRecorder.record(
            MistralUsageEntry.polish(
                date: Date(), requestedModel: configuration.model, usage: usage))
    }

    /// Extracts the assistant's answer from a decoded chat/completions
    /// response object, for every server we talk to.
    ///
    /// `choices[0].message.content` is a plain string on every
    /// OpenAI-compatible server, and on Mistral whenever reasoning is off.
    /// A reasoning-capable Mistral model instead returns a LIST of content
    /// chunks: `{"type":"thinking", …}` for the trace and
    /// `{"type":"text","text":…}` for the answer. We always ask for
    /// `reasoning_effort: "none"`, but a model that reasons anyway must not
    /// turn a perfectly good polish into `invalidResponse` — so the list shape
    /// is accepted defensively, keeping only the `text` chunks and dropping
    /// the trace (which is never what the user dictated).
    ///
    /// Returns nil when no assistant text can be found; the caller maps that
    /// to `invalidResponse`, as it always has.
    static func assistantText(inResponseObject json: [String: Any]) -> String? {
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { return nil }

        if let content = message["content"] as? String {
            return content
        }
        guard let chunks = message["content"] as? [[String: Any]] else { return nil }
        let text = chunks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return text.isEmpty ? nil : text
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
        // Bifrost's opt-in header only means anything to Bifrost, and Mistral
        // is not it: the Mistral shape emits no passthrough extras at all, so
        // the header would only advertise fields that are not there.
        if configuration.passthroughExtraParameters, configuration.requestShape != .mistral {
            urlRequest.setValue("true", forHTTPHeaderField: "x-bf-passthrough-extra-params")
        }
        urlRequest.timeoutInterval = Self.timeoutInterval(for: request)
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
        // An empty system prompt sends no system message. polishd checkpoints
        // every message but the last as a prompt-cache prefix, and its two
        // slots belong to the two dictation profiles: a one-message request
        // (term suggestions) has no prefix, so it cannot evict them.
        let systemMessages = request.systemPrompt.isEmpty
            ? []
            : [["role": "system", "content": request.systemPrompt]]
        let messages = systemMessages
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
            if let presencePenalty = defaults.presencePenalty {
                body["presence_penalty"] = presencePenalty
            }
        }
        if let maxTokens = request.maxTokens {
            body["max_tokens"] = maxTokens
        }

        if configuration.requestShape == .mistral {
            // Mistral's request schema is closed. Everything below this point
            // is an extension some self-hosted server invented; sending one
            // costs the whole request (422), so the Mistral shape stops here
            // with only the fields the schema names.
            let polishEffort =
                configuration.mistralReasoningEffort
                ?? MistralReasoningEffort.forModel(configuration.model)
            let effort = request.prefersDeepReasoning ? polishEffort.deepened : polishEffort
            if let wireValue = effort.wireValue {
                body["reasoning_effort"] = wireValue
            }
            return try JSONSerialization.data(withJSONObject: body)
        }

        if let defaults = configuration.samplingDefaults {
            if let topK = defaults.topK {
                body["top_k"] = topK
            }
            if let minP = defaults.minP {
                body["min_p"] = minP
            }
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
