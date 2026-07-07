import Foundation
import MLXLLM
import MLXLMCommon

/// The seam between the HTTP layer and inference: the router talks to this
/// protocol so it can be unit-tested with a stub, no Metal required.
public protocol ChatResponding: Sendable {
    func respond(
        to messages: [ChatCompletionMessage],
        temperature: Float?,
        maxTokens: Int?
    ) async throws -> String
}

public enum ChatRespondingError: Error, CustomStringConvertible {
    case unknownRole(String)

    public var description: String {
        switch self {
        case .unknownRole(let role):
            "unsupported message role: \(role)"
        }
    }
}

/// Loads the MLX model once and answers chat requests against it. Each
/// request gets a fresh `ChatSession` (no cross-request history); the
/// `ModelContainer` serializes concurrent generation internally.
public final class MLXPolishModel: ChatResponding, @unchecked Sendable {
    private let container: ModelContainer
    private let defaultMaxTokens: Int

    private init(container: ModelContainer, defaultMaxTokens: Int) {
        self.container = container
        self.defaultMaxTokens = defaultMaxTokens
    }

    public static func load(directory: URL, defaultMaxTokens: Int) async throws -> MLXPolishModel {
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: TransformersTokenizerLoader()
        )
        return MLXPolishModel(container: container, defaultMaxTokens: defaultMaxTokens)
    }

    public func respond(
        to messages: [ChatCompletionMessage],
        temperature: Float?,
        maxTokens: Int?
    ) async throws -> String {
        var parameters = GenerateParameters()
        if let temperature {
            parameters.temperature = temperature
        }
        parameters.maxTokens = maxTokens ?? defaultMaxTokens

        let chat = try messages.map { message -> Chat.Message in
            switch message.role {
            case "system": .system(message.content)
            case "user": .user(message.content)
            case "assistant": .assistant(message.content)
            default: throw ChatRespondingError.unknownRole(message.role)
            }
        }

        let session = ChatSession(container, generateParameters: parameters)
        return try await session.respond(to: chat)
    }
}
