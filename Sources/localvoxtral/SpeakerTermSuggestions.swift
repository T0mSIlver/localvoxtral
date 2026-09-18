import Foundation
import Observation

/// "Suggest terms": the polishing model reads the user's recent dictations
/// and proposes the names they keep saying. Telling a name from an ordinary
/// word is left to the model on purpose — no capitalization or dictionary
/// heuristic survives German, where every noun is capitalized and compounds
/// are in no dictionary (owner ruling, 2026-09-18).
///
/// What the app itself guarantees, whatever the model returns: a suggestion is
/// never added without a click, and a dismissed one is never shown again.
enum SpeakerTermSuggestions {
    static let maxDictations = 120
    static let maxRequestCharacters = 60_000
    static let maxShown = 12
    static let maxDismissed = 400
    static let timeoutSeconds: TimeInterval = 240

    /// Measured on the owner's 74-dictation history (2026-09-18): one batch
    /// request with this wording gave the cleanest list on GLM 5.3 — it
    /// recovered "Qwen" from Coin/Kuen/QN and dropped Cohere, OpenShift and
    /// `toolInput`, all of which sat in the final texts as polish mistakes.
    static let systemPrompt = """
        You are given many short texts dictated by ONE person over several weeks (speech recognition output, some of it wrong). Build the list of proper names and technical terms this person really uses, so a dictation app can learn to spell them: products, tools, models, companies, people, projects, acronyms. Any language.
        Rules:
        - Only terms that appear in at least 3 different texts (count variants and misrecognitions of the same name together).
        - Spell each term the correct, canonical way. If the same name shows up under several spellings, some of them recognition errors, output the ONE right spelling.
        - Do NOT list ordinary words or ordinary phrases of the language, even technical ones ("functional specifications", "tech lead", "knowledge graph"): a speech recognizer already spells those. Do NOT list things that look like recognition errors or that do not fit the sentences they appear in (for example a code identifier dropped into ordinary prose).
        - Do NOT list anything from the "already known" or "refused" lists in the message.
        Return only a JSON array of strings, most frequent first, no commentary. Return [] if there is nothing.
        """

    /// One key per term however it is cased, spaced or punctuated, so
    /// "SessionStart", "session start" and "Session-Start" are one refusal.
    static func key(_ term: String) -> String {
        String(term.caseFoldedForMatching.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    /// Newest first in, newest first out, cut where the request would get too
    /// large for one call.
    static func selected(_ texts: [String]) -> [String] {
        var budget = maxRequestCharacters
        var result: [String] = []
        for text in texts.prefix(maxDictations) {
            let trimmed = text.trimmed
            guard !trimmed.isEmpty else { continue }
            guard trimmed.count <= budget else { break }
            budget -= trimmed.count
            result.append(trimmed)
        }
        return result
    }

    static func request(texts: [String], terms: [String], dismissed: [String]) -> LLMPolishingRequest {
        var sections: [String] = []
        if !terms.isEmpty {
            sections.append("Already known (do not list): " + terms.joined(separator: ", "))
        }
        if !dismissed.isEmpty {
            sections.append("Refused by the user (do not list): " + dismissed.joined(separator: ", "))
        }
        sections.append(
            texts.enumerated().map { "[text \($0.offset + 1)]\n\($0.element)" }
                .joined(separator: "\n\n")
        )
        let message = sections.joined(separator: "\n\n")
        return LLMPolishingRequest(
            inputText: message,
            systemPrompt: systemPrompt,
            userPrompts: [message],
            timeoutSeconds: timeoutSeconds
        )
    }

    /// The first JSON array in the reply; strings, or objects carrying a
    /// `term`. Anything else is no suggestions rather than an error — a model
    /// that wraps its answer in prose still gets read.
    static func parse(_ reply: String) -> [String] {
        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"),
              start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return array.compactMap { element in
            (element as? String) ?? ((element as? [String: Any])?["term"] as? String)
        }
    }

    /// The model is asked not to repeat known or refused terms, but only this
    /// filter is what makes "never again" true.
    static func filtered(_ candidates: [String], terms: [String], dismissed: [String]) -> [String] {
        let blocked = Set((terms + dismissed).map(key))
        var seen = Set<String>()
        return SpeakerTerms.sanitized(candidates).filter { candidate in
            let candidateKey = key(candidate)
            return !candidateKey.isEmpty
                && !blocked.contains(candidateKey)
                && seen.insert(candidateKey).inserted
        }
    }

    /// Checks the model's "at least 3 texts" claim by counting: candidates
    /// that really occur in three or more dictations come first, the rest keep
    /// the model's order behind them. Nothing is dropped — a name the model
    /// recovered from misrecognitions ("Qwen" from Coin/Kuen) occurs in no
    /// text at all and is the most valuable suggestion there is. A weaker
    /// model that lists everything it saw (Mistral Medium, 2026-09-18) gets
    /// its first twelve from what the user actually keeps saying.
    static func ranked(_ candidates: [String], texts: [String]) -> [String] {
        let folded = texts.map(\.caseFoldedForMatching)
        func occurrences(of term: String) -> Int {
            let escaped = NSRegularExpression.escapedPattern(for: term.caseFoldedForMatching)
            guard let regex = try? NSRegularExpression(
                pattern: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
            ) else { return 0 }
            return folded.reduce(0) { count, text in
                let range = NSRange(text.startIndex..., in: text)
                return count + (regex.firstMatch(in: text, range: range) == nil ? 0 : 1)
            }
        }
        let confirmed = candidates.filter { occurrences(of: $0) >= 3 }
        let confirmedSet = Set(confirmed)
        return confirmed + candidates.filter { !confirmedSet.contains($0) }
    }
}

@MainActor
@Observable
final class SpeakerTermSuggestionModel {
    enum Phase: Equatable {
        case idle
        case loading
        case nothingFound
        case failed(String)
    }

    private(set) var suggestions: [String] = []
    private(set) var phase: Phase = .idle

    private let settings: SettingsStore
    private let recentTexts: @MainActor () async -> [String]
    private let service: @MainActor () -> any LLMPolishingServicing

    init(
        settings: SettingsStore,
        recentTexts: @escaping @MainActor () async -> [String],
        service: @escaping @MainActor () -> any LLMPolishingServicing
    ) {
        self.settings = settings
        self.recentTexts = recentTexts
        self.service = service
    }

    func suggest() async {
        guard phase != .loading else { return }
        guard let configuration = settings.llmPolishingConfiguration else {
            phase = .failed("Set up a polishing model first.")
            return
        }
        phase = .loading
        let texts = SpeakerTermSuggestions.selected(await recentTexts())
        guard !texts.isEmpty else {
            phase = .failed("No dictations to read yet.")
            return
        }
        Log.polishing.info("Term suggestions requested: \(texts.count, privacy: .public) dictations")
        do {
            let result = try await service().polish(
                request: SpeakerTermSuggestions.request(
                    texts: texts,
                    terms: settings.polishSpeakerTerms,
                    dismissed: settings.polishDismissedTermSuggestions
                ),
                configuration: configuration
            )
            suggestions = Array(SpeakerTermSuggestions.ranked(
                SpeakerTermSuggestions.filtered(
                    SpeakerTermSuggestions.parse(result.polishedText),
                    terms: settings.polishSpeakerTerms,
                    dismissed: settings.polishDismissedTermSuggestions
                ),
                texts: texts
            ).prefix(SpeakerTermSuggestions.maxShown))
            phase = suggestions.isEmpty ? .nothingFound : .idle
            Log.polishing.info("Term suggestions received: \(self.suggestions.count, privacy: .public)")
        } catch {
            phase = .failed("The polishing model did not answer.")
            Log.polishing.error(
                "Term suggestions failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func accept(_ term: String) {
        settings.polishSpeakerTerms = SpeakerTerms.sanitized(settings.polishSpeakerTerms + [term])
        suggestions.removeAll { $0 == term }
    }

    func acceptAll() {
        settings.polishSpeakerTerms = SpeakerTerms.sanitized(settings.polishSpeakerTerms + suggestions)
        suggestions = []
    }

    func dismiss(_ term: String) {
        settings.dismissTermSuggestion(term)
        suggestions.removeAll { $0 == term }
    }
}
