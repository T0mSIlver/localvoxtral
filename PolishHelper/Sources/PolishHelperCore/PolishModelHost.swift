import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// The seam between the HTTP layer and inference: the router talks to this
/// protocol so it can be unit-tested with a stub, no Metal required.
public protocol ChatResponding: Sendable {
    func respond(
        to messages: [ChatCompletionMessage],
        sampling: ChatSamplingParameters
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

/// Loads the MLX model once and answers chat requests against it, reusing a
/// KV-state checkpoint of the stable prompt prefix across requests.
///
/// Every polish request shares [system prompt, instructions user message] and
/// varies only in the final transcript message, so the prefix's prefill work
/// (the bulk of the prompt) is paid once and cloned per request via
/// `KVCache.copy()`. Cloning — never trimming — is load-bearing: Qwen3.5 is
/// hybrid linear-attention and its `MambaCache` layers cannot be trimmed, the
/// same reason the previous mlx-lm engine only reused stored true prefixes
/// for this model. The `ModelContainer` serializes concurrent requests.
public final class MLXPolishModel: ChatResponding, @unchecked Sendable {
    private let container: ModelContainer
    private let defaultMaxTokens: Int

    /// KV state for the templated stable prefix. `caches` is never mutated
    /// after creation — each request extends a `copy()`. Only touched inside
    /// `container.perform`, which serializes all access.
    private struct PrefixSnapshot {
        let prefixTokens: [Int]
        let caches: [KVCache]
    }
    private var prefixSnapshot: PrefixSnapshot?

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
        sampling: ChatSamplingParameters
    ) async throws -> String {
        var parameters = GenerateParameters()
        if let temperature = sampling.temperature {
            parameters.temperature = temperature
        }
        if let topP = sampling.topP {
            parameters.topP = topP
        }
        if let topK = sampling.topK {
            parameters.topK = topK
        }
        if let minP = sampling.minP {
            parameters.minP = minP
        }
        if let presencePenalty = sampling.presencePenalty {
            parameters.presencePenalty = presencePenalty
        }
        parameters.maxTokens = sampling.maxTokens ?? defaultMaxTokens
        // Deterministic sampling: identical requests must produce identical
        // output, like the previous engine's within-state behavior — the
        // polish eval baseline and user experience both rely on it. The
        // sampler is seeded per request, so prefix-cache reuse does not
        // change the sampled sequence for a given prompt.
        parameters.seed = 0
        let generateParameters = parameters

        let templateMessages = try messages.map { message -> [String: any Sendable] in
            guard ["system", "user", "assistant"].contains(message.role) else {
                throw ChatRespondingError.unknownRole(message.role)
            }
            return ["role": message.role, "content": message.content]
        }
        let prefixMessageCount = PromptPrefixPlan.cacheablePrefix(of: messages)?.count

        return try await container.perform { context in
            let fullTokens = try context.tokenizer.applyChatTemplate(messages: templateMessages)
            let (cache, promptTokens) = try self.promptState(
                fullTokens: fullTokens,
                templateMessages: templateMessages,
                prefixMessageCount: prefixMessageCount,
                context: context,
                parameters: generateParameters
            )

            let input = LMInput(tokens: MLXArray(promptTokens))
            let stream = try MLXLMCommon.generate(
                input: input, cache: cache, parameters: generateParameters, context: context)
            var output = ""
            for await generation in stream {
                if let chunk = generation.chunk {
                    output += chunk
                }
            }
            return output
        }
    }

    /// The KV cache to generate on (nil for a fresh one) and the prompt
    /// tokens still to prefill — the full prompt, or just the suffix past the
    /// checkpointed prefix.
    private func promptState(
        fullTokens: [Int],
        templateMessages: [[String: any Sendable]],
        prefixMessageCount: Int?,
        context: ModelContext,
        parameters: GenerateParameters
    ) throws -> ([KVCache]?, [Int]) {
        guard let prefixMessageCount,
            let prefixEncoder = context.tokenizer as? ChatPrefixEncoding
        else {
            return (nil, fullTokens)
        }

        let prefixTokens = try prefixEncoder.encodeChatPrefix(
            messages: Array(templateMessages.prefix(prefixMessageCount)))

        switch PromptPrefixPlan.plan(fullTokens: fullTokens, cachedPrefixTokens: prefixTokens) {
        case .fullPrefill:
            // Template quirk guard: if the templated prefix is not a true
            // token prefix of the full prompt, reuse would corrupt output —
            // prefill everything instead and say so.
            PolishdLog.info(
                "prompt cache: templated prefix (\(prefixTokens.count) tokens) is not a "
                    + "prefix of the prompt (\(fullTokens.count) tokens); full prefill")
            return (nil, fullTokens)

        case .reusePrefix(let suffixTokens):
            if let snapshot = prefixSnapshot, snapshot.prefixTokens == prefixTokens {
                PolishdLog.info(
                    "prompt cache: hit — reusing \(prefixTokens.count) prefix tokens, "
                        + "prefilling \(suffixTokens.count)")
                return (snapshot.caches.map { $0.copy() }, suffixTokens)
            }

            let caches = try prefill(tokens: prefixTokens, context: context, parameters: parameters)
            prefixSnapshot = PrefixSnapshot(prefixTokens: prefixTokens, caches: caches)
            PolishdLog.info(
                "prompt cache: checkpointed \(prefixTokens.count) prefix tokens; "
                    + "prefilling \(suffixTokens.count)")
            return (caches.map { $0.copy() }, suffixTokens)
        }
    }

    /// Prefill `tokens` into a fresh cache WITHOUT sampling: `prepare`
    /// consumes all full prefill windows, then the remaining tokens are
    /// folded in with one forward pass whose logits are discarded. After
    /// this the cache holds exactly `tokens`.
    private func prefill(
        tokens: [Int],
        context: ModelContext,
        parameters: GenerateParameters
    ) throws -> [KVCache] {
        let caches = context.model.newCache(parameters: parameters)
        let input = LMInput(tokens: MLXArray(tokens))
        switch try context.model.prepare(
            input, cache: caches, windowSize: parameters.prefillStepSize)
        {
        case .tokens(let remaining):
            withPreparedCache(caches, lengths: remaining.sequenceLengths) {
                _ = context.model(
                    remaining[text: .newAxis],
                    cache: caches.isEmpty ? nil : caches,
                    state: nil)
            }
        case .logits:
            break
        }
        eval(caches)
        return caches
    }
}
