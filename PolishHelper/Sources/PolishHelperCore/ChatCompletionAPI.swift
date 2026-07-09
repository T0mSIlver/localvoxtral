import Foundation

/// Wire types for the OpenAI chat-completions subset the app's
/// `LLMPolishingService` actually sends and reads. Streaming is deliberately
/// unsupported (the polish path is a single non-streaming request).
public struct ChatCompletionRequest: Codable, Sendable {
    public var model: String?
    public var messages: [ChatCompletionMessage]
    public var chatTemplateArguments: [String: ChatTemplateArgumentValue]?
    public var temperature: Float?
    public var topP: Float?
    public var topK: Int?
    public var minP: Float?
    public var presencePenalty: Float?
    public var maxTokens: Int?
    public var stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case chatTemplateArguments = "chat_template_kwargs"
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case minP = "min_p"
        case presencePenalty = "presence_penalty"
        case maxTokens = "max_tokens"
        case stream
    }

    public init(
        model: String? = nil,
        messages: [ChatCompletionMessage],
        chatTemplateArguments: [String: ChatTemplateArgumentValue]? = nil,
        temperature: Float? = nil,
        topP: Float? = nil,
        topK: Int? = nil,
        minP: Float? = nil,
        presencePenalty: Float? = nil,
        maxTokens: Int? = nil,
        stream: Bool? = nil
    ) {
        self.model = model
        self.messages = messages
        self.chatTemplateArguments = chatTemplateArguments
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.presencePenalty = presencePenalty
        self.maxTokens = maxTokens
        self.stream = stream
    }

    public var sampling: ChatSamplingParameters {
        ChatSamplingParameters(
            temperature: temperature,
            topP: topP,
            topK: topK,
            minP: minP,
            presencePenalty: presencePenalty,
            maxTokens: maxTokens
        )
    }
}

public enum ChatTemplateArgumentValue: Codable, Equatable, Hashable, Sendable {
    case bool(Bool)
    case string(String)
    case int(Int)
    case double(Double)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            throw DecodingError.typeMismatch(
                ChatTemplateArgumentValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "chat_template_kwargs values must be Bool, String, Int, or Double"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        }
    }

    var templateContextValue: any Sendable {
        switch self {
        case .bool(let value):
            value
        case .string(let value):
            value
        case .int(let value):
            value
        case .double(let value):
            value
        }
    }
}

/// The sampling knobs a request may override; nil fields keep the engine
/// defaults (mlx-swift-lm's `GenerateParameters` — the model card's
/// recommended values are deliberately NOT applied, matching the old
/// mlx-lm engine's behavior).
public struct ChatSamplingParameters: Equatable, Sendable {
    public var temperature: Float?
    public var topP: Float?
    public var topK: Int?
    public var minP: Float?
    public var presencePenalty: Float?
    public var maxTokens: Int?

    public init(
        temperature: Float? = nil,
        topP: Float? = nil,
        topK: Int? = nil,
        minP: Float? = nil,
        presencePenalty: Float? = nil,
        maxTokens: Int? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.presencePenalty = presencePenalty
        self.maxTokens = maxTokens
    }
}

public struct ChatCompletionMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct ChatCompletionResponse: Codable, Sendable {
    public struct Choice: Codable, Sendable {
        public var index: Int
        public var message: ChatCompletionMessage
        public var finishReason: String

        enum CodingKeys: String, CodingKey {
            case index
            case message
            case finishReason = "finish_reason"
        }

        public init(index: Int, message: ChatCompletionMessage, finishReason: String) {
            self.index = index
            self.message = message
            self.finishReason = finishReason
        }
    }

    public var id: String
    public var object: String
    public var created: Int
    public var model: String
    public var choices: [Choice]

    public init(id: String, created: Int, model: String, content: String) {
        self.id = id
        self.object = "chat.completion"
        self.created = created
        self.model = model
        self.choices = [
            Choice(
                index: 0,
                message: ChatCompletionMessage(role: "assistant", content: content),
                finishReason: "stop"
            )
        ]
    }
}

public struct ChatCompletionErrorResponse: Codable, Sendable {
    public struct ErrorBody: Codable, Sendable {
        public var message: String
        public var type: String
    }

    public var error: ErrorBody

    public init(message: String, type: String) {
        self.error = ErrorBody(message: message, type: type)
    }
}
