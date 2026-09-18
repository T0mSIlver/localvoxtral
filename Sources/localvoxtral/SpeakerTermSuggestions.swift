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
    /// Mistral Medium at high effort took 170 s on 74 dictations.
    static let timeoutSeconds: TimeInterval = 420

    /// Measured on the owner's 74-dictation history (2026-09-18): one batch
    /// request with this wording gave the cleanest list on GLM 5.3 — it
    /// recovered "Qwen" from Coin/Kuen/QN and dropped Cohere, OpenShift and
    /// `toolInput`, all of which sat in the final texts as polish mistakes.
    static let instructions = """
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
    /// large for one call. `reserved` is what the rest of the message already
    /// spends (the known and refused lists can reach tens of kilobytes).
    static func selected(_ texts: [String], reserved: Int = 0) -> [String] {
        var budget = maxRequestCharacters - reserved
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

    static func listSections(terms: [String], dismissed: [String]) -> [String] {
        var sections: [String] = []
        if !terms.isEmpty {
            sections.append("Already known (do not list): " + terms.joined(separator: ", "))
        }
        if !dismissed.isEmpty {
            sections.append("Refused by the user (do not list): " + dismissed.joined(separator: ", "))
        }
        return sections
    }

    /// ONE user message and no system message: see `LLMPolishingService
    /// .requestBody` — this keeps the request out of polishd's prompt cache.
    static func request(texts: [String], terms: [String], dismissed: [String]) -> LLMPolishingRequest {
        let sections = [instructions]
            + listSections(terms: terms, dismissed: dismissed)
            + [texts.enumerated().map { "[text \($0.offset + 1)]\n\($0.element)" }
                .joined(separator: "\n\n")]
        let message = sections.joined(separator: "\n\n")
        return LLMPolishingRequest(
            inputText: message,
            systemPrompt: "",
            userPrompts: [message],
            timeoutSeconds: timeoutSeconds,
            prefersDeepReasoning: true
        )
    }

    /// The first span of the reply that parses as a JSON array; strings, or
    /// objects carrying a `term`. A reply wrapped in prose, a code fence or a
    /// reasoning trace with its own brackets still gets read; a reply with no
    /// array is no suggestions rather than an error.
    static func parse(_ reply: String) -> [String] {
        var searchStart = reply.startIndex
        while let start = reply[searchStart...].firstIndex(of: "[") {
            var end = reply.endIndex
            while let close = reply[start..<end].lastIndex(of: "]") {
                if let data = String(reply[start...close]).data(using: .utf8),
                   let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
                {
                    let terms = array.compactMap { element in
                        (element as? String) ?? ((element as? [String: Any])?["term"] as? String)
                    }
                    if !terms.isEmpty || array.isEmpty { return terms }
                }
                end = close
            }
            searchStart = reply.index(after: start)
        }
        return []
    }

    /// The model is asked not to repeat known or refused terms, but only this
    /// filter is what makes "never again" true.
    static func filtered(_ candidates: [String], terms: [String], dismissed: [String]) -> [String] {
        let blocked = Set((terms + dismissed).map(key))
        var seen = Set<String>()
        // Blocked terms go BEFORE `sanitized`, which caps the list: a model
        // that lists everything would otherwise spend the cap on terms the
        // user already has and lose the new ones behind them.
        return SpeakerTerms.sanitized(candidates.filter { candidate in
            let candidateKey = key(candidate)
            return !candidateKey.isEmpty
                && !blocked.contains(candidateKey)
                && seen.insert(candidateKey).inserted
        })
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
    /// What the running state shows: how much is being read, and since when.
    private(set) var readingCount = 0
    private(set) var startedAt: Date?

    private let settings: SettingsStore
    private let recentTexts: @MainActor () async -> [String]
    private let service: @MainActor () -> any LLMPolishingServicing
    /// Why the button cannot be used right now, or nil. Measured on the
    /// owner's history (2026-09-19): the bundled 4B took 177 s, listed the
    /// polish mistakes it was told to leave out and ended in a repetition
    /// loop, while holding the helper's single generation slot against every
    /// polish. Batches of ten returned nothing. Hosted models only.
    private let unavailableReasonProvider: @MainActor () -> String?
    private let now: @MainActor () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        settings: SettingsStore,
        recentTexts: @escaping @MainActor () async -> [String],
        service: @escaping @MainActor () -> any LLMPolishingServicing,
        unavailableReason: @escaping @MainActor () -> String? = { nil },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.settings = settings
        self.recentTexts = recentTexts
        self.service = service
        self.unavailableReasonProvider = unavailableReason
        self.now = now
    }

    /// The button's action. The model owns the task so a dictation can stop it.
    func start() {
        guard phase != .loading else { return }
        task = Task { await suggest() }
    }

    /// The Stop button.
    func stop() {
        guard phase == .loading else { return }
        task?.cancel()
        task = nil
        phase = .idle
        Log.polishing.info("Term suggestions stopped by the user")
    }

    var unavailableReason: String? { unavailableReasonProvider() }

    func suggest() async {
        guard phase != .loading else { return }
        if let reason = unavailableReasonProvider() {
            phase = .failed(reason)
            return
        }
        guard let configuration = settings.llmPolishingConfiguration else {
            phase = .failed("Set up a polishing model first.")
            return
        }
        readingCount = 0
        startedAt = now()
        phase = .loading
        let terms = settings.polishSpeakerTerms
        let dismissed = settings.polishDismissedTermSuggestions
        let reserved = SpeakerTermSuggestions.instructions.count
            + SpeakerTermSuggestions.listSections(terms: terms, dismissed: dismissed)
                .reduce(0) { $0 + $1.count }
        let texts = SpeakerTermSuggestions.selected(await recentTexts(), reserved: reserved)
        guard phase == .loading else { return }
        guard !texts.isEmpty else {
            phase = .failed("No dictations to read yet.")
            return
        }
        readingCount = texts.count
        Log.polishing.info("Term suggestions requested: \(texts.count, privacy: .public) dictations")
        do {
            let result = try await service().polish(
                request: SpeakerTermSuggestions.request(
                    texts: texts, terms: terms, dismissed: dismissed
                ),
                configuration: configuration
            )
            // Stopped while waiting: the row already went back to its button.
            guard phase == .loading, !Task.isCancelled else { return }
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
            guard phase == .loading else { return }
            phase = .failed("The polishing model did not answer.")
            Log.polishing.error(
                "Term suggestions failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func accept(_ term: String) {
        guard add([term]) else { return }
        suggestions.removeAll { $0 == term }
    }

    func acceptAll() {
        guard add(suggestions) else { return }
        suggestions = []
    }

    func dismiss(_ term: String) {
        settings.dismissTermSuggestion(term)
        suggestions.removeAll { $0 == term }
    }

    /// False when the list's cap swallowed any of them: the chips stay and
    /// the row says why, instead of vanishing as if they had been added.
    private func add(_ terms: [String]) -> Bool {
        let updated = SpeakerTerms.sanitized(settings.polishSpeakerTerms + terms)
        let wanted = Set(terms.map(SpeakerTermSuggestions.key))
        guard wanted.isSubset(of: Set(updated.map(SpeakerTermSuggestions.key))) else {
            phase = .failed("Terms list is full.")
            return false
        }
        settings.polishSpeakerTerms = updated
        if case .failed = phase { phase = .idle }
        return true
    }
}
