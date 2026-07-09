import Foundation

/// Prefix-cache planning for chat prompts: pure token/message math, no MLX,
/// so it is unit-testable without Metal.
///
/// The reusable prefix is every message except the last — the polish request
/// shape is [system, instructions user message, transcript user message],
/// where only the transcript varies between requests. This mirrors the
/// mlx-lm server's deliberate `messages[:-1]` cache segmentation, which is
/// what made "system + first user cached, transcript not" work there.
/// Qwen3.5's KV cache mixes in linear-attention state that cannot be
/// trimmed, so reuse is only sound for a stored TRUE token prefix — hence
/// the strict is-prefix check in ``plan(fullTokens:cachedPrefixTokens:)``
/// instead of any longest-common-prefix trimming.
public enum PromptPrefixPlan: Equatable, Sendable {
    /// The cached prefix is a strict prefix of the full prompt: reuse the
    /// snapshot's KV state and prefill only `suffixTokens`.
    case reusePrefix(suffixTokens: [Int])
    /// No usable prefix: prefill the full prompt from scratch.
    case fullPrefill

    /// The messages whose templated tokens are worth checkpointing: all but
    /// the last (varying) one. Nil when there is nothing stable to cache.
    public static func cacheablePrefix(
        of messages: [ChatCompletionMessage]
    ) -> [ChatCompletionMessage]? {
        guard messages.count >= 2 else { return nil }
        return Array(messages.dropLast())
    }

    /// Decide whether `cachedPrefixTokens` can serve as the already-prefilled
    /// head of `fullTokens`. Requires a strict prefix with a non-empty
    /// remainder (generation needs at least one fresh token to prefill).
    public static func plan(
        fullTokens: [Int],
        cachedPrefixTokens: [Int]
    ) -> PromptPrefixPlan {
        guard !cachedPrefixTokens.isEmpty,
            cachedPrefixTokens.count < fullTokens.count,
            fullTokens.starts(with: cachedPrefixTokens)
        else {
            return .fullPrefill
        }
        return .reusePrefix(suffixTokens: Array(fullTokens.dropFirst(cachedPrefixTokens.count)))
    }
}
