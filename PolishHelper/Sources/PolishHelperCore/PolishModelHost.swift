import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// The seam between the HTTP layer and inference: the router talks to this
/// protocol so it can be unit-tested with a stub, no Metal required.
public protocol ChatResponding: Sendable {
    func respond(
        to messages: [ChatCompletionMessage],
        chatTemplateArguments: [String: ChatTemplateArgumentValue]?,
        sampling: ChatSamplingParameters
    ) async throws -> ChatReply
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

/// Loads the MLX model once and answers chat requests against it, reusing
/// KV-state checkpoints of the stable prompt prefixes across requests.
///
/// Every polish request shares [system prompt, instructions user message] and
/// varies only in the final transcript message, so the prefix's prefill work
/// (the bulk of the prompt) is paid once and cloned per request via
/// `KVCache.copy()`. Cloning — never trimming — is load-bearing: Qwen3.5 is
/// hybrid linear-attention and its `MambaCache` layers cannot be trimmed, the
/// same reason the previous mlx-lm engine only reused stored true prefixes
/// for this model. The `ModelContainer` serializes concurrent requests.
///
/// Checkpoints live in a small LRU slot store (`PromptPrefixSlotStore`,
/// default 2 slots) so two alternating prompt profiles (standard vs agent
/// dictation) both stay warm instead of invalidating each other on every
/// switch — with one slot, each alternation re-prefilled the full prefix.
///
/// With a multi-token-prediction drafter loaded, temperature-0 requests decode
/// speculatively: the drafter proposes the next token, the model verifies it
/// in the same forward pass, and the output stays identical to plain greedy
/// decoding. Sampled requests decode one token at a time, because mlx-swift-lm
/// only speculates for Qwen MTP at temperature 0.
public final class MLXPolishModel: ChatResponding, @unchecked Sendable {
    private let container: ModelContainer
    private let defaultMaxTokens: Int
    /// Only touched inside `container.perform`, like the prefix slots.
    private let drafter: (any MTPDrafterModel)?

    /// KV states for the templated stable prefixes, keyed by exact prefix
    /// tokens + chat-template kwargs. Stored caches are never mutated after
    /// creation — each request extends a `copy()`. Only touched inside
    /// `container.perform`, which serializes all access.
    private var prefixSlots: PromptPrefixSlotStore<[KVCache]>

    private init(
        container: ModelContainer,
        defaultMaxTokens: Int,
        promptCacheSlots: Int,
        drafter: (any MTPDrafterModel)?
    ) {
        self.container = container
        self.defaultMaxTokens = defaultMaxTokens
        self.drafter = drafter
        self.prefixSlots = PromptPrefixSlotStore(capacity: promptCacheSlots)
    }

    public static func load(
        directory: URL,
        defaultMaxTokens: Int,
        promptCacheSlots: Int = 2,
        speculativeDecoding: SpeculativeDecodingMode = .off
    ) async throws -> MLXPolishModel {
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: TransformersTokenizerLoader()
        )
        var drafter: (any MTPDrafterModel)?
        if speculativeDecoding == .mtp {
            // A checkpoint without the head, or one downloaded before the
            // app fetched it, still polishes; it just decodes token by token.
            do {
                drafter = try await MTPDrafterLoader.load(modelDirectory: directory)
                PolishdLog.info("speculative decoding: MTP head loaded")
            } catch {
                PolishdLog.error("speculative decoding off: \(error)")
            }
        }
        return MLXPolishModel(
            container: container,
            defaultMaxTokens: defaultMaxTokens,
            promptCacheSlots: promptCacheSlots,
            drafter: drafter
        )
    }

    public func respond(
        to messages: [ChatCompletionMessage],
        chatTemplateArguments: [String: ChatTemplateArgumentValue]? = nil,
        sampling: ChatSamplingParameters
    ) async throws -> ChatReply {
        let start = ContinuousClock.now
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
        let chatTemplateContext: [String: any Sendable]? = chatTemplateArguments?
            .mapValues { $0.templateContextValue }

        return try await container.perform { context in
            let fullTokens = try context.tokenizer.applyChatTemplate(
                messages: templateMessages,
                tools: nil,
                additionalContext: chatTemplateContext
            )
            let (cache, promptTokens) = try self.promptState(
                fullTokens: fullTokens,
                templateMessages: templateMessages,
                prefixMessageCount: prefixMessageCount,
                chatTemplateArguments: chatTemplateArguments,
                chatTemplateContext: chatTemplateContext,
                context: context,
                parameters: generateParameters
            )

            let input = LMInput(tokens: MLXArray(promptTokens))
            let stream: AsyncStream<Generation>
            if let drafter = self.drafter, generateParameters.temperature == 0 {
                stream = try MLXLMCommon.generate(
                    input: input, cache: cache, parameters: generateParameters,
                    context: context, mtpDrafter: drafter)
            } else {
                stream = try MLXLMCommon.generate(
                    input: input, cache: cache, parameters: generateParameters, context: context)
            }
            var output = ""
            var firstChunk: ContinuousClock.Instant?
            var info: GenerateCompletionInfo?
            for await generation in stream {
                switch generation {
                case .chunk(let chunk):
                    if firstChunk == nil { firstChunk = .now }
                    output += chunk
                case .info(let completion):
                    info = completion
                default:
                    break
                }
            }
            if let reason = info?.passthroughReason {
                PolishdLog.info("speculative decoding stood down: \(reason)")
            }
            let end = ContinuousClock.now
            let timings = PolishTimings(
                firstTokenMilliseconds: Self.milliseconds(start.duration(to: firstChunk ?? end)),
                totalMilliseconds: Self.milliseconds(start.duration(to: end)),
                promptTokens: fullTokens.count,
                cachedPromptTokens: fullTokens.count - promptTokens.count,
                completionTokens: info?.generationTokenCount ?? 0,
                draftTokens: info?.proposedDraftTokens,
                acceptedDraftTokens: info?.acceptedDraftTokens
            )
            return ChatReply(content: output, timings: timings)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }

    /// The KV cache to generate on (nil for a fresh one) and the prompt
    /// tokens still to prefill — the full prompt, or just the suffix past the
    /// checkpointed prefix.
    private func promptState(
        fullTokens: [Int],
        templateMessages: [[String: any Sendable]],
        prefixMessageCount: Int?,
        chatTemplateArguments: [String: ChatTemplateArgumentValue]?,
        chatTemplateContext: [String: any Sendable]?,
        context: ModelContext,
        parameters: GenerateParameters
    ) throws -> ([KVCache]?, [Int]) {
        guard let prefixMessageCount,
            let prefixEncoder = context.tokenizer as? ChatPrefixEncoding
        else {
            return (nil, fullTokens)
        }

        let prefixTokens = try prefixEncoder.encodeChatPrefix(
            messages: Array(templateMessages.prefix(prefixMessageCount)),
            additionalContext: chatTemplateContext
        )

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
            let key = PromptPrefixSlotStore<[KVCache]>.Key(
                prefixTokens: prefixTokens,
                chatTemplateArguments: chatTemplateArguments
            )
            if let caches = prefixSlots.lookup(key) {
                PolishdLog.info(
                    "prompt cache: hit — reusing \(prefixTokens.count) prefix tokens, "
                        + "prefilling \(suffixTokens.count) (\(slotSummary()))")
                return (caches.map { $0.copy() }, suffixTokens)
            }

            let caches = try prefill(tokens: prefixTokens, context: context, parameters: parameters)
            if prefixSlots.store(key, state: caches) {
                PolishdLog.info(
                    "prompt cache: evicted least-recently-used slot "
                        + "(capacity \(prefixSlots.capacity))")
            }
            PolishdLog.info(
                "prompt cache: checkpointed \(prefixTokens.count) prefix tokens; "
                    + "prefilling \(suffixTokens.count) (\(slotSummary()))")
            return (caches.map { $0.copy() }, suffixTokens)
        }
    }

    /// Count-only slot telemetry appended to the existing cache log lines
    /// (whose prefixes the integration suite greps — keep them stable).
    private func slotSummary() -> String {
        let counters = prefixSlots.counters
        return "slots \(prefixSlots.count)/\(prefixSlots.capacity), "
            + "hits \(counters.hits), misses \(counters.misses), evictions \(counters.evictions)"
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
        let caches = try context.model.newCache(parameters: parameters)
        let input = LMInput(tokens: MLXArray(tokens))
        switch try context.model.prepare(
            input, cache: caches, state: nil, prefill: parameters.prefill)
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
