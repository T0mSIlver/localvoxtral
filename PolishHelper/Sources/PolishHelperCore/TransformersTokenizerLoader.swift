import Foundation
import MLXLMCommon
import Tokenizers

/// Hand-written equivalent of mlx-swift-lm's `#huggingFaceTokenizerLoader()`
/// macro expansion (Libraries/MLXHuggingFaceMacros). Using the macro would
/// pull swift-syntax + swift-huggingface into the build for two trivial
/// bridge types; we only ever load tokenizers from a local directory.
public struct TransformersTokenizerLoader: TokenizerLoader {
    public init() {}

    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

/// Templating a chat *prefix* — the messages before the varying final one —
/// WITHOUT the generation prompt, so the result is a true token prefix of the
/// full templated prompt and its KV state can be checkpointed for reuse.
/// MLXLMCommon's `Tokenizer` protocol always adds the generation prompt, so
/// this is a separate seam the prefix cache downcasts to.
public protocol ChatPrefixEncoding {
    func encodeChatPrefix(
        messages: [[String: any Sendable]],
        additionalContext: [String: any Sendable]?
    ) throws -> [Int]
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers uses `decode(tokens:)` instead of `decode(tokenIds:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

extension TokenizerBridge: ChatPrefixEncoding {
    func encodeChatPrefix(
        messages: [[String: any Sendable]],
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            // The full-control protocol requirement: the convenience
            // overloads with defaulted addGenerationPrompt live on concrete
            // tokenizers, not the existential.
            return try upstream.applyChatTemplate(
                messages: messages,
                chatTemplate: nil,
                addGenerationPrompt: false,
                truncation: false,
                maxLength: nil,
                tools: nil,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
