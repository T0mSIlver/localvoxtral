import Foundation

/// The token sizes Settings shows next to the polish prompt's parts (#1007),
/// estimated by `PolishPromptTokenRatio`.
@MainActor
enum PolishPromptTokenText {
    /// The ratio of the polish backend Settings has selected, whether or not
    /// polishing is on.
    static func ratio(settings: SettingsStore, ledger: UsageLedger?) -> PolishPromptTokenRatio {
        let backend: UsageEntry.Backend = switch settings.polishingBackendMode {
        case .managedLocal: .bundledHelper
        case .mistralAPI: .mistral
        case .externalURL: .userServer
        }
        return PolishPromptTokenRatio(entries: ledger?.entries() ?? [], backend: backend)
    }

    /// "≈ 1,230 tokens", or both profiles when the agent one is on:
    /// "≈ 1,230 · agent ≈ 1,760 tokens".
    static func instructions(standard: Int, agent: Int?) -> String {
        guard let agent else { return "≈ \(approximate(standard)) tokens" }
        return "≈ \(approximate(standard)) · agent ≈ \(approximate(agent)) tokens"
    }

    /// "12 terms · ≈ 90 tokens", nil with no terms.
    static func globalTerms(_ terms: [String], ratio: PolishPromptTokenRatio) -> String? {
        let sanitized = SpeakerTerms.sanitized(terms)
        guard !sanitized.isEmpty else { return nil }
        // The header and the line do not depend on the instructions.
        let characters = PolishPromptParts.globalTermCharacters(
            LLMPromptTemplates(systemContent: "", userContent: ""), profile: "", terms: sanitized)
        let count = "\(sanitized.count) term\(sanitized.count == 1 ? "" : "s")"
        return "\(count) · ≈ \(approximate(ratio.tokens(termListCharacters: characters))) tokens"
    }

    /// "up to ≈ 120 tokens", nil when no term of the project is sent yet.
    static func projectTerms(_ terms: [LearnedTerm], ratio: PolishPromptTokenRatio) -> String? {
        let sent = terms.filter { $0.isConfirmed(minimumDictations: LearnedTerms.confirmedDictations) }
        guard !sent.isEmpty else { return nil }
        let characters = PolishPromptParts.projectTermCharacters(sent.map(\.term))
        return "up to ≈ \(approximate(ratio.tokens(termListCharacters: characters))) tokens"
    }

    /// Tens from 100 up: an estimate's last digit means nothing.
    static func approximate(_ tokens: Int) -> String {
        let rounded = tokens >= 100 ? Int((Double(tokens) / 10).rounded()) * 10 : tokens
        return rounded.formatted()
    }
}
