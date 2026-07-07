import Foundation

/// Wire types for the OpenAI chat-completions subset the app's
/// `LLMPolishingService` actually sends and reads. Streaming is deliberately
/// unsupported (the polish path is a single non-streaming request).
public struct ChatCompletionRequest: Codable, Sendable {
    public var model: String?
    public var messages: [ChatCompletionMessage]
    public var temperature: Float?
    public var maxTokens: Int?
    public var stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }

    public init(
        model: String? = nil,
        messages: [ChatCompletionMessage],
        temperature: Float? = nil,
        maxTokens: Int? = nil,
        stream: Bool? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
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
