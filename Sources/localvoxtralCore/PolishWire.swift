import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The polishing model's wire dialect, for every request sent to it: polish,
// term suggestions, the prompt warmup, and quick capture's router and first
// draft (#1851). Each caller states what it asks in a `PolishWireRequest`;
// the configuration's shape alone decides the URL, headers, body and how the
// reply is read.

/// Which wire dialect a polishing server speaks. The app talks to
/// self-hosted OpenAI-compatible servers (llama.cpp, mlx-lm, vLLM, the bundled
/// polishd), to Mistral's hosted API and to Anthropic's, and no two accept the
/// same body.
package enum LLMPolishingRequestShape: String, Sendable {
    /// Every self-hosted OpenAI-compatible server. Emits the union of fields
    /// those servers understand — including the llama.cpp / mlx-lm / Bifrost
    /// extras (`top_k`, `min_p`, `chat_template_kwargs`,
    /// `thinking_budget_tokens`, the `x-bf-passthrough-extra-params` header),
    /// which a server that does not know them ignores.
    case openAICompatible

    /// Mistral's hosted `/v1/chat/completions`. Its `ChatCompletionRequest`
    /// schema is closed: it rejects unknown body fields, so this shape emits
    /// ONLY `model`, `messages`, `temperature`, `top_p`, `presence_penalty`,
    /// `max_tokens`, `reasoning_effort` and `prompt_cache_key` — never
    /// `top_k`, `min_p`, `chat_template_kwargs` or `thinking_budget_tokens`,
    /// and never the `x-bf-passthrough-extra-params` header, even when the
    /// configuration carries them (a catalog model's sampling defaults do).
    /// Those four are llama.cpp / mlx-lm / Bifrost extras with no Mistral
    /// equivalent.
    ///
    /// `reasoning_effort` asks for the least reasoning the model takes
    /// (`MistralReasoningEffort`): polishing must never pay a reasoning
    /// trace's latency or output tokens to insert one space before a question
    /// mark, and a value the model does not take is a 400.
    case mistral

    /// Anthropic's `/v1/messages`, chosen for an External URL server on
    /// `api.anthropic.com` (#1849). The system prompt is its own field,
    /// `max_tokens` is required, and current models reject non-default
    /// sampling, so the body carries no sampling field at all. Depth is
    /// `output_config.effort`: `high` for a request that prefers deep
    /// reasoning, `low` for every other.
    case anthropic

    /// The shape an External URL server speaks, read from its host.
    package static func forExternalEndpoint(_ url: URL) -> LLMPolishingRequestShape {
        url.host?.lowercased() == AnthropicPolishDefaults.host ? .anthropic : .openAICompatible
    }
}

/// What a Mistral request says about reasoning. Mistral answers 400 for a
/// value the model does not take, so this is per model, not a constant:
/// measured 2026-09-18 against the live API.
package enum MistralReasoningEffort: String, Sendable {
    /// `"none"`: reasoning switched off — Mistral's own reasoning models.
    case off
    /// GLM rejects `none` (it takes `low`/`high`/`max`) and reasons at length
    /// when the field is absent; `low` answers a short polish with no trace.
    case low
    /// The field is not sent: a model without reasoning rejects it outright
    /// ("reasoning_effort is not enabled for this model").
    case omitted
    /// For work nobody is waiting on (term suggestions). `/v1/models` only
    /// says WHETHER a model reasons, not which levels it takes, but `"high"`
    /// is the one value every reasoning model accepted (live API, 2026-09-19:
    /// GLM takes low/high/max, Mistral's own models none/high) — one below
    /// the top on GLM, the top elsewhere, and no per-model table.
    case high

    package var wireValue: String? {
        switch self {
        case .off: return "none"
        case .low: return "low"
        case .omitted: return nil
        case .high: return "high"
        }
    }

    /// The effort for a request that asked to think hard: `high` wherever the
    /// polish effort says the model reasons at all.
    package var deepened: Self { self == .omitted ? .omitted : .high }

    /// The model's lowest effort, from its id alone: every model is assumed
    /// to reason, which is what the default model does. The app's
    /// `forModel(_:catalog:)` also asks the catalog.
    package static func forModel(_ modelID: String) -> Self {
        isGLM(modelID) ? .low : .off
    }

    /// Z.ai's GLM models, which Mistral's API also serves.
    package static func isGLM(_ modelID: String) -> Bool {
        modelID.lowercased().split(separator: "-").contains("glm")
    }
}

/// Wire constants for Anthropic's Messages API.
package enum AnthropicPolishDefaults {
    package static let host = "api.anthropic.com"
    package static let endpoint = URL(string: "https://api.anthropic.com")!
    /// Anthropic API mode's default: fast enough to polish on stop.
    package static let model = "claude-haiku-5-5"
    /// The models the Anthropic API mode's picker offers, fastest first.
    package static let models: [AnthropicPolishModel] = [
        AnthropicPolishModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5"),
        AnthropicPolishModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
    ]
    package static let apiVersion = "2023-06-01"
    /// Required by the API. Covers the reply plus whatever the model thinks
    /// at low effort; a polish is about as long as its dictation.
    package static let maxTokens = 16000
}

/// A model the Anthropic API mode's picker offers.
package struct AnthropicPolishModel: Sendable, Hashable, Identifiable {
    package let id: String
    package let name: String

    package init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One polishing server and every setting that changes the bytes sent to it.
package struct LLMPolishingConfiguration: Sendable {
    package let endpointURL: URL
    package let apiKey: String
    package let model: String
    package let samplingDefaults: PolishSamplingDefaults?
    package let chatTemplateArguments: [String: Bool]?
    /// llama.cpp per-request reasoning cap. Nil preserves the normal OpenAI
    /// request shape; zero disables reasoning when the server supports it.
    package let thinkingBudgetTokens: Int?
    /// Bifrost drops provider-specific body fields unless this opt-in header
    /// is present. Other OpenAI-compatible servers harmlessly ignore it.
    package let passthroughExtraParameters: Bool
    /// The wire dialect this configuration's requests are serialized in.
    package let requestShape: LLMPolishingRequestShape
    /// Mistral shape only. Nil derives it from the model id alone
    /// (`MistralReasoningEffort.forModel`), which is right for every
    /// reasoning model; Settings passes the catalog's answer so a model
    /// without reasoning gets no field at all.
    package let mistralReasoningEffort: MistralReasoningEffort?
    /// Who answers, for the usage ledger. Settings names the bundled helper;
    /// otherwise the shape decides: Mistral's, or a server the user configured.
    package let usageBackend: UsageEntry.Backend

    package init(
        endpointURL: URL,
        apiKey: String,
        model: String,
        samplingDefaults: PolishSamplingDefaults? = nil,
        chatTemplateArguments: [String: Bool]? = nil,
        thinkingBudgetTokens: Int? = nil,
        passthroughExtraParameters: Bool = false,
        requestShape: LLMPolishingRequestShape = .openAICompatible,
        mistralReasoningEffort: MistralReasoningEffort? = nil,
        usageBackend: UsageEntry.Backend? = nil
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
        self.usageBackend = usageBackend ?? (requestShape == .mistral ? .mistral : .userServer)
    }
}

/// One request to the polishing model, in no server's dialect.
package struct PolishWireRequest: Sendable {
    package enum Purpose: Sendable {
        /// A dictation's polish, term suggestions or the warmup: the
        /// configuration's sampling (temperature 0.3 unless it sets one), the
        /// self-hosted extras, the Bifrost header and Mistral's prompt cache
        /// key.
        case polish
        /// Quick capture's router and first draft: temperature 0 and no
        /// other sampling, and of the self-hosted extras only the switches
        /// that decide whether a reasoning model thinks first.
        case quickCapture
    }

    package enum Effort: Sendable {
        /// What polish asks: Mistral's configured effort, Anthropic's `low`.
        case standard
        /// Think hard: Mistral's `high` where the model reasons, Anthropic's
        /// `high`.
        case deep
        /// The least the model takes, whatever polish uses: GLM's `low`,
        /// Mistral's own `none`, nothing for a model the catalog lists
        /// without reasoning (#1365). Anthropic's `low`. At a higher effort
        /// GLM 5.3 once spent the whole token cap reasoning (#918).
        case least
    }

    package let systemPrompt: String
    package let userPrompts: [String]
    package let maxTokens: Int?
    package let timeout: TimeInterval
    package let purpose: Purpose
    package let effort: Effort

    package init(
        systemPrompt: String,
        userPrompts: [String],
        maxTokens: Int? = nil,
        timeout: TimeInterval,
        purpose: Purpose,
        effort: Effort = .standard
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompts = userPrompts
        self.maxTokens = maxTokens
        self.timeout = timeout
        self.purpose = purpose
        self.effort = effort
    }
}

/// The polishing model's answer, read in the configuration's dialect.
package struct PolishWireReply: Sendable {
    /// The answer's text, without any reasoning trace. Nil when the reply
    /// carries none.
    package let text: String?
    /// The reply ended at a token limit, so its text is a prefix.
    package let stoppedAtOutputLimit: Bool
    /// The model declined the request; any text it carries is partial.
    package let refused: Bool
    package let usage: LLMTokenUsage?
}

extension LLMPolishingConfiguration {
    // MARK: URL and headers

    /// Where every request to this server goes.
    package var requestURL: URL {
        switch requestShape {
        case .anthropic: return Self.anthropicMessagesURL(endpointURL)
        case .openAICompatible, .mistral: return Self.normalizedChatCompletionsURL(endpointURL)
        }
    }

    package func urlRequest(for request: PolishWireRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: requestURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch requestShape {
        case .anthropic:
            urlRequest.setValue(AnthropicPolishDefaults.apiVersion, forHTTPHeaderField: "anthropic-version")
            if !apiKey.isEmpty {
                urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            }
        case .openAICompatible, .mistral:
            if !apiKey.isEmpty {
                urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        // Bifrost's opt-in header only means anything to Bifrost, and neither
        // hosted API is it: their shapes emit no passthrough extras at all, so
        // the header would only advertise fields that are not there.
        if request.purpose == .polish, passthroughExtraParameters, requestShape == .openAICompatible {
            urlRequest.setValue("true", forHTTPHeaderField: "x-bf-passthrough-extra-params")
        }
        urlRequest.timeoutInterval = request.timeout
        urlRequest.httpBody = try body(for: request)
        return urlRequest
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
    package static func normalizedChatCompletionsURL(_ url: URL) -> URL {
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

    /// The Messages API URL on the host the user typed: whatever path they
    /// gave (`/`, `/v1`, `/v1/messages`) becomes `/v1/messages`.
    package static func anthropicMessagesURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.path = "/v1/messages"
        return components.url ?? url
    }

    // MARK: Body

    /// The JSON body, keys sorted so equal requests are equal bytes.
    package func body(for request: PolishWireRequest) throws -> Data {
        let body: [String: Any]
        switch requestShape {
        case .anthropic: body = anthropicBody(for: request)
        case .openAICompatible, .mistral: body = chatCompletionsBody(for: request)
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private func chatCompletionsBody(for request: PolishWireRequest) -> [String: Any] {
        // An empty system prompt sends no system message. polishd checkpoints
        // every message but the last as a prompt-cache prefix, and its two
        // slots belong to the two dictation profiles: a one-message request
        // (term suggestions) has no prefix, so it cannot evict them.
        let systemMessages = request.systemPrompt.isEmpty
            ? []
            : [["role": "system", "content": request.systemPrompt]]
        var body: [String: Any] = [
            "model": model,
            "messages": systemMessages + request.userPrompts.map { ["role": "user", "content": $0] },
        ]
        switch request.purpose {
        case .polish:
            body["temperature"] = samplingDefaults?.temperature ?? 0.3
            if let topP = samplingDefaults?.topP {
                body["top_p"] = topP
            }
            if let presencePenalty = samplingDefaults?.presencePenalty {
                body["presence_penalty"] = presencePenalty
            }
        case .quickCapture:
            body["temperature"] = 0
        }
        if let maxTokens = request.maxTokens {
            body["max_tokens"] = maxTokens
        }

        if requestShape == .mistral {
            // Mistral's request schema is closed. Everything below this point
            // is an extension some self-hosted server invented; sending one
            // costs the whole request (422), so the Mistral shape stops here
            // with only the fields the schema names.
            if let wireValue = mistralEffort(request.effort).wireValue {
                body["reasoning_effort"] = wireValue
            }
            if request.purpose == .polish, let cacheKey = Self.mistralPromptCacheKey(for: request) {
                body["prompt_cache_key"] = cacheKey
            }
            return body
        }

        if request.purpose == .polish {
            if let topK = samplingDefaults?.topK {
                body["top_k"] = topK
            }
            if let minP = samplingDefaults?.minP {
                body["min_p"] = minP
            }
        }
        if let chatTemplateArguments {
            body["chat_template_kwargs"] = chatTemplateArguments
        }
        if let thinkingBudgetTokens {
            body["thinking_budget_tokens"] = thinkingBudgetTokens
        }
        return body
    }

    private func mistralEffort(_ effort: PolishWireRequest.Effort) -> MistralReasoningEffort {
        let standard = mistralReasoningEffort ?? .forModel(model)
        switch effort {
        case .standard: return standard
        case .deep: return standard.deepened
        case .least: return mistralReasoningEffort == .omitted ? .omitted : .forModel(model)
        }
    }

    /// Mistral caches the shared start of prompts server-side and bills cached
    /// tokens at 10%; requests carrying the same `prompt_cache_key` are more
    /// likely to land where that start is cached. The key names the fixed
    /// start itself (every message but the last), so requests that share it
    /// share a key. The fixed start includes About you, so the digest is an
    /// HMAC under a key drawn at launch: a plain hash would let anyone who
    /// sees the key test guesses at the speaker's text. Nil when there is no
    /// fixed start: a one-message request.
    package static func mistralPromptCacheKey(for request: PolishWireRequest) -> String? {
        let prefixUserPrompts = request.userPrompts.dropLast()
        guard !request.systemPrompt.isEmpty || !prefixUserPrompts.isEmpty else { return nil }
        let prefix = ([request.systemPrompt] + prefixUserPrompts).joined(separator: "\u{0}")
        let digest = HMACSHA256.authenticationCode(for: Data(prefix.utf8), key: promptCacheKeySalt)
        return "lvx-polish-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static let promptCacheKeySalt: Data = {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }()

    /// The Messages API body. Every user prompt is one text block of a single
    /// user message, so the request needs no alternating roles. The fixed
    /// start (system prompt and every prompt but the last) ends on a
    /// `cache_control` breakpoint: the API caches that prefix for 5 minutes
    /// and bills reads at a tenth of input. A prefix shorter than the
    /// model's minimum simply isn't cached.
    private func anthropicBody(for request: PolishWireRequest) -> [String: Any] {
        let ephemeral: [String: Any] = ["type": "ephemeral"]
        var blocks: [[String: Any]] = request.userPrompts.map { ["type": "text", "text": $0] }
        var system: [[String: Any]] = request.systemPrompt.isEmpty
            ? []
            : [["type": "text", "text": request.systemPrompt]]
        if blocks.count > 1 {
            blocks[blocks.count - 2]["cache_control"] = ephemeral
        } else if !system.isEmpty {
            system[0]["cache_control"] = ephemeral
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens ?? AnthropicPolishDefaults.maxTokens,
            "messages": [["role": "user", "content": blocks]],
            "output_config": ["effort": request.effort == .deep ? "high" : "low"],
        ]
        if !system.isEmpty {
            body["system"] = system
        }
        return body
    }

    // MARK: Reply

    /// Nil when the body is not a JSON object.
    package func reply(to data: Data) -> PolishWireReply? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return reply(toResponseObject: json)
    }

    /// The answer in `json`, read the way this shape's server writes it.
    ///
    /// OpenAI-compatible and Mistral: `choices[0].message.content` is a plain
    /// string on every OpenAI-compatible server, and on Mistral whenever
    /// reasoning is off. A reasoning-capable Mistral model instead returns a
    /// LIST of content chunks: `{"type":"thinking", …}` for the trace and
    /// `{"type":"text","text":…}` for the answer. A model that reasons anyway
    /// must not turn a good answer into a failure, so the list is accepted,
    /// keeping only the `text` chunks. `finish_reason` `length`, or Mistral's
    /// `model_length` when the context window runs out mid-answer, is a cut;
    /// a missing one counts as complete, as servers that omit it always did.
    ///
    /// Anthropic: a top-level `content` list of the same kind of blocks, and
    /// a top-level `stop_reason`: `max_tokens` or
    /// `model_context_window_exceeded` is a cut, `refusal` a decline.
    package func reply(toResponseObject json: [String: Any]) -> PolishWireReply {
        let usage = LLMTokenUsage(responseObject: json)
        switch requestShape {
        case .anthropic:
            let stopReason = json["stop_reason"] as? String
            return PolishWireReply(
                text: Self.text(ofBlocks: json["content"]),
                stoppedAtOutputLimit: stopReason == "max_tokens" || stopReason == "model_context_window_exceeded",
                refused: stopReason == "refusal",
                usage: usage
            )
        case .openAICompatible, .mistral:
            let choice = (json["choices"] as? [[String: Any]])?.first
            let content = (choice?["message"] as? [String: Any])?["content"]
            let finishReason = choice?["finish_reason"] as? String
            return PolishWireReply(
                text: content as? String ?? Self.text(ofBlocks: content),
                stoppedAtOutputLimit: finishReason == "length" || finishReason == "model_length",
                refused: false,
                usage: usage
            )
        }
    }

    private static func text(ofBlocks content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return text.isEmpty ? nil : text
    }
}
