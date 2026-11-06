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
    /// Showing what was heard beside what was kept nearly doubles a
    /// dictation's size; at 60 000 the pass read 75 of the owner's 120 and
    /// missed names whose evidence sat in the rest (#612). Input is the cheap
    /// part of this request: reasoning output was 60–85 % of its cost.
    static let maxRequestCharacters = 100_000
    static let maxShown = 12
    static let maxDismissed = 400
    /// Mistral Medium at high effort took 170 s on 74 dictations.
    static let timeoutSeconds: TimeInterval = 420

    /// The first wording, measured on the owner's 74-dictation history
    /// (2026-09-18), recovered "Qwen" from Coin/Kuen and dropped polish
    /// mistakes, but read only polished text and so also listed words the
    /// recognizer spells right (IBM, Mac, Word: #612). This one shows what
    /// was heard and asks only for the recognizer's mistakes, each with the
    /// wrong forms `TermSuggestionScreen` can check against the transcripts.
    static let instructions = """
        You are given many short texts dictated by ONE person over several weeks. "heard:" is what the speech recognizer wrote. "final:", present only when it differs, is the corrected text that was kept; its corrections can be wrong too. Build the list of proper names and technical terms that the recognizer gets WRONG for this person, so a dictation app can learn to spell them: products, tools, models, companies, people, projects, acronyms. Any language.
        Rules:
        - List a term only if the recognizer got its letters wrong in at least one "heard:" line: misspelled, split or joined, or heard as other words. Capital letters alone do not count ("MAC" for Mac is not a mistake). A term the recognizer writes right every time does NOT belong, however rare or technical: the list exists only to fix its mistakes.
        - Only terms that appear in at least 3 different texts, right and wrong spellings counted together.
        - Spell each term the correct, canonical way. If one name shows up under several spellings, output the ONE right spelling.
        - Do NOT list ordinary words or ordinary phrases of the language, even technical ones ("functional specifications", "tech lead", "knowledge graph"). Do NOT list a term found only in "final:" lines that does not fit what was heard or the sentence around it (a correction mistake, for example a code identifier dropped into ordinary prose).
        - Do NOT list anything from the "already known" or "refused" lists in the message.
        Return only a JSON array, most frequent mistakes first, no commentary. Each item is {"term": "<canonical spelling>", "heard": ["<each wrong form, copied exactly from the heard: lines>"]}. Return [] if there is nothing.
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
    /// spends (the known and refused lists can reach tens of kilobytes); a
    /// dictation spends what `block` renders of it.
    static func selected(
        _ dictations: [TermSuggestionScreen.Dictation], reserved: Int = 0
    ) -> [TermSuggestionScreen.Dictation] {
        var budget = maxRequestCharacters - reserved
        var result: [TermSuggestionScreen.Dictation] = []
        for dictation in dictations.prefix(maxDictations) {
            let trimmed = TermSuggestionScreen.Dictation(
                raw: dictation.raw.trimmed, final: dictation.final.trimmed
            )
            guard !trimmed.raw.isEmpty || !trimmed.final.isEmpty else { continue }
            let cost = block(trimmed).count
            guard cost <= budget else { break }
            budget -= cost
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

    /// ONE user message and no system message: see `LLMPolishingConfiguration
    /// .body(for:)` — this keeps the request out of polishd's prompt cache.
    static func request(
        dictations: [TermSuggestionScreen.Dictation], terms: [String], dismissed: [String]
    ) -> LLMPolishingRequest {
        let sections = [instructions]
            + listSections(terms: terms, dismissed: dismissed)
            + [dictations.enumerated().map { "[text \($0.offset + 1)]\n" + block($0.element) }
                .joined(separator: "\n\n")]
        let message = sections.joined(separator: "\n\n")
        return LLMPolishingRequest(
            inputText: message,
            systemPrompt: "",
            userPrompts: [message],
            timeoutSeconds: timeoutSeconds,
            prefersDeepReasoning: true,
            usageFeature: .termSuggestions
        )
    }

    /// One dictation as the model reads it: what was heard, and what was kept
    /// when that differs.
    static func block(_ dictation: TermSuggestionScreen.Dictation) -> String {
        dictation.final == dictation.raw
            ? "heard: \(dictation.raw)"
            : "heard: \(dictation.raw)\nfinal: \(dictation.final)"
    }

    static func parse(_ reply: String) -> [String] {
        parseCandidates(reply).map(\.term)
    }

    /// The first span of the reply that parses as a JSON array; strings, or
    /// objects carrying a `term` and, optionally, its `heard` forms. A reply wrapped in prose, a code fence or a
    /// reasoning trace with its own brackets still gets read; a reply with no
    /// array is no suggestions rather than an error.
    static func parseCandidates(_ reply: String) -> [(term: String, heard: [String])] {
        var searchStart = reply.startIndex
        while let start = reply[searchStart...].firstIndex(of: "[") {
            var end = reply.endIndex
            while let close = reply[start..<end].lastIndex(of: "]") {
                if let data = String(reply[start...close]).data(using: .utf8),
                   let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
                {
                    let terms = array.compactMap { element -> (term: String, heard: [String])? in
                        if let term = element as? String { return (term, []) }
                        guard let object = element as? [String: Any],
                              let term = object["term"] as? String
                        else { return nil }
                        return (term, (object["heard"] as? [Any])?.compactMap { $0 as? String } ?? [])
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
}

/// The Suggestions row, fed by two producers with one rule between them.
///
/// The app offers what it has already watched polishing fix in the user's
/// projects (`LearnedTerms`), for free, as soon as the pane opens. The button
/// asks a hosted model to read the dictation history for names the grounding
/// sources never saw. Either way a suggestion is never added without a click,
/// and a refused one never comes back.
@MainActor
@Observable
final class SpeakerTermSuggestionModel {
    enum Phase: Equatable {
        case idle
        case loading
        case nothingFound
        case failed(String)
    }

    /// How a run ended, for `TermSuggestionCadence`: only a run the model
    /// answered counts as one.
    enum RunOutcome: Equatable {
        case completed
        case failed
        /// The Stop button.
        case stopped
        /// Refused before a request went out, or a stopped run's request
        /// coming back after the fact.
        case notRun
    }

    private(set) var suggestions: [String] = [] {
        didSet {
            let known = Set(oldValue.map(SpeakerTermSuggestions.key))
            let grew = suggestions.contains { !known.contains(SpeakerTermSuggestions.key($0)) }
            if grew, !isPaneVisible { hasUnseenSuggestions = true }
        }
    }
    private(set) var phase: Phase = .idle
    /// Chips that landed while nobody was looking at the row. The sidebar
    /// badge is how a background run says it found something.
    private(set) var hasUnseenSuggestions = false
    @ObservationIgnored private var isPaneVisible = false
    /// Every finished run, the button's included. `countAtStart` is what
    /// `startInBackground` was given, handed back so the cadence never has to
    /// guess which run an outcome belongs to.
    @ObservationIgnored var onRunFinished: (@MainActor (RunOutcome, _ countAtStart: Int?) -> Void)?
    /// What the running state shows: how much is being read, and since when.
    private(set) var readingCount = 0
    private(set) var startedAt: Date?

    private let settings: SettingsStore
    private let recentDictations: @MainActor () async -> [TermSuggestionScreen.Dictation]
    /// Terms the app has watched polishing fix, strongest evidence first.
    /// Offered with no model call and no API credits — the evidence is
    /// already on this machine.
    private let learnedTerms: @MainActor () -> [String]
    /// The project and skill names every polish already carries (#1024),
    /// known like the user's own terms.
    private let sentNames: @MainActor () -> [String]
    /// The current project's terms, which its polish carries too (#1442).
    /// Never sent in the suggestion request, only screened out of its answer.
    private let currentProjectTerms: @MainActor () -> [String]
    private let service: @MainActor () -> any LLMPolishingServicing
    /// Why the button cannot be used right now, or nil. Measured on the
    /// owner's history (2026-09-19): the bundled 4B took 177 s, listed the
    /// polish mistakes it was told to leave out and ended in a repetition
    /// loop, while holding the helper's single generation slot against every
    /// polish. Batches of ten returned nothing. Hosted models only.
    private let unavailableReasonProvider: @MainActor () -> String?
    private let now: @MainActor () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Which run owns `phase`. A stopped run whose request returns late must
    /// not touch the row of the run that replaced it (review, 2026-09-21).
    @ObservationIgnored private var runID = 0
    /// Where each chip on the row came from, for the outcome counts.
    @ObservationIgnored private var sourceByKey: [String: TermSuggestionOutcomes.Source] = [:]

    /// The app's defaults key for `TermSuggestionOutcomes` (LVX-11).
    static let outcomesDefaultsKey = "settings.term_suggestion_outcomes"

    init(
        settings: SettingsStore,
        recentDictations: @escaping @MainActor () async -> [TermSuggestionScreen.Dictation],
        learnedTerms: @escaping @MainActor () -> [String] = { [] },
        sentNames: @escaping @MainActor () -> [String] = { [] },
        currentProjectTerms: @escaping @MainActor () -> [String] = { [] },
        service: @escaping @MainActor () -> any LLMPolishingServicing,
        unavailableReason: @escaping @MainActor () -> String? = { nil },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.settings = settings
        self.recentDictations = recentDictations
        self.learnedTerms = learnedTerms
        self.sentNames = sentNames
        self.currentProjectTerms = currentProjectTerms
        self.service = service
        self.unavailableReasonProvider = unavailableReason
        self.now = now
    }

    /// What a suggestion must not repeat: the user's terms and the project
    /// and skill names.
    private var knownTerms: [String] {
        settings.polishSpeakerTerms + sentNames()
    }

    /// The candidates no polish request already carries.
    private func unsent(_ candidates: [String]) -> [String] {
        TermSuggestionScreen.unsent(candidates, carried: knownTerms + currentProjectTerms())
    }

    /// Chips the app can offer for free: terms it has already watched the
    /// polishing model fix, confirmed across dictations. Called when the pane
    /// appears, so the list is there before anyone presses a button.
    ///
    /// They pass the screen the model's answer passes: a learned term is
    /// confirmed by being matched three times, which a term the recognizer
    /// already spells right is too. On the owner's data (2026-11-04) both
    /// refused chips that came from learned terms ("dashboard", "DeepSeek")
    /// were of that kind.
    ///
    /// Additive — a suggestion already on screen stays, and one the user has
    /// added or refused never comes back, also when they did so while the
    /// dictations were being read.
    func refreshLearnedSuggestions() async {
        let candidates = learnedCandidates()
        guard !candidates.isEmpty else { return }
        let screened = TermSuggestionScreen.screened(candidates, dictations: await recentDictations())
        let learned = learnedCandidates(from: screened)
        guard !learned.isEmpty else { return }
        suggestions = Array((suggestions + learned).prefix(SpeakerTermSuggestions.maxShown))
        noteShown(source: .learned)
        // Never while a run is in flight: `.loading` is the row's progress
        // state, and dropping out of it would hide the Stop button and the
        // clock from a user whose request is still running.
        if phase == .nothingFound { phase = .idle }
    }

    /// The learned terms (or `terms`, screened from them) not known, refused
    /// or already on screen.
    private func learnedCandidates(from terms: [String]? = nil) -> [String] {
        let shown = Set(suggestions.map(SpeakerTermSuggestions.key))
        return SpeakerTermSuggestions.filtered(
            unsent(terms ?? learnedTerms()),
            terms: knownTerms,
            dismissed: settings.polishDismissedTermSuggestions
        ).filter { !shown.contains(SpeakerTermSuggestions.key($0)) }
    }

    /// What the Text processing sidebar row shows: every chip waiting, from
    /// the moment one lands unseen until the pane is opened.
    var badgeCount: Int { hasUnseenSuggestions ? suggestions.count : 0 }

    func paneAppeared() {
        isPaneVisible = true
        hasUnseenSuggestions = false
        Task { await refreshLearnedSuggestions() }
    }

    func paneDisappeared() {
        isPaneVisible = false
    }

    /// The button's action. The model owns the task so a dictation can stop it.
    /// It hands the cadence its starting count like a background run: the
    /// dictations saved while the model answers were not read (LVX-93).
    func start() {
        guard phase != .loading else { return }
        let countAtStart = settings.termSuggestionDictationsSinceRun
        task = Task { await suggest(countAtStart: countAtStart) }
    }

    /// A run nobody asked for (`TermSuggestionCadence`). Same request, same
    /// row; what differs is that a failure or an empty answer leaves no
    /// message behind for a user who never pressed anything.
    func startInBackground(countAtStart: Int) {
        guard phase != .loading else { return }
        task = Task { await suggest(background: true, countAtStart: countAtStart) }
    }

    #if DEBUG
    /// Test seam: the run in flight, so a suite awaits a stopped run's end
    /// instead of yielding.
    var debugTask: Task<Void, Never>? { task }
    #endif

    /// The Stop button.
    func stop() {
        guard phase == .loading else { return }
        task?.cancel()
        task = nil
        runID += 1
        phase = .idle
        Log.polishing.info("Term suggestions stopped by the user")
        onRunFinished?(.stopped, nil)
    }

    var unavailableReason: String? { unavailableReasonProvider() }

    @discardableResult
    func suggest(background: Bool = false, countAtStart: Int? = nil) async -> RunOutcome {
        guard phase != .loading else { return .notRun }
        let outcome = await run(background: background)
        onRunFinished?(outcome, countAtStart)
        return outcome
    }

    private func run(background: Bool) async -> RunOutcome {
        if let reason = unavailableReasonProvider() {
            phase = background ? .idle : .failed(reason)
            return .notRun
        }
        guard let configuration = settings.llmPolishingConfiguration else {
            phase = background ? .idle : .failed("Set up a polishing model first.")
            return .notRun
        }
        runID += 1
        let thisRun = runID
        var ownsRow: Bool { runID == thisRun && phase == .loading && !Task.isCancelled }
        readingCount = 0
        startedAt = now()
        phase = .loading
        let terms = knownTerms
        let dismissed = settings.polishDismissedTermSuggestions
        let reserved = SpeakerTermSuggestions.instructions.count
            + SpeakerTermSuggestions.listSections(terms: terms, dismissed: dismissed)
                .reduce(0) { $0 + $1.count }
        let dictations = SpeakerTermSuggestions.selected(await recentDictations(), reserved: reserved)
        guard ownsRow else { return .notRun }
        guard !dictations.isEmpty else {
            phase = background ? .idle : .failed("No dictations to read yet.")
            return .notRun
        }
        readingCount = dictations.count
        Log.polishing.info("Term suggestions requested: \(dictations.count, privacy: .public) dictations")
        do {
            let result = try await service().polish(
                request: SpeakerTermSuggestions.request(
                    dictations: dictations, terms: terms, dismissed: dismissed
                ),
                configuration: configuration
            )
            // Stopped while waiting: the row already went back to its button.
            guard ownsRow else { return .notRun }
            let candidates = SpeakerTermSuggestions.parseCandidates(result.polishedText)
            let found = TermSuggestionScreen.screened(
                SpeakerTermSuggestions.filtered(
                    unsent(candidates.map(\.term)),
                    terms: knownTerms,
                    dismissed: settings.polishDismissedTermSuggestions
                ),
                dictations: dictations,
                heard: Dictionary(candidates.map { ($0.term, $0.heard) }, uniquingKeysWith: +)
            )
            // What the run found leads — it is what the user waited minutes for
            // — and the chips already on screen keep their place behind it, as
            // far as the row's twelve allow. Both sides go back through
            // `filtered`: a chip shown before the run may have been added or
            // refused while it ran, and that filter is the only thing making
            // "never again" true (review, 2026-09-20).
            suggestions = Array(
                SpeakerTermSuggestions.filtered(
                    unsent(found + suggestions),
                    terms: knownTerms,
                    dismissed: settings.polishDismissedTermSuggestions
                ).prefix(SpeakerTermSuggestions.maxShown)
            )
            noteShown(source: .model)
            phase = suggestions.isEmpty && !background ? .nothingFound : .idle
            // A run that started before the pane had refreshed, or that ran
            // for minutes while dictation taught the app new terms, must not
            // leave the free chips out (review, 2026-09-20). Runs AFTER the
            // phase leaves `.loading`, which is what lets it fill.
            await refreshLearnedSuggestions()
            Log.polishing.info("Term suggestions received: \(self.suggestions.count, privacy: .public)")
            return .completed
        } catch {
            guard ownsRow else { return .notRun }
            phase = background ? .idle : .failed("The polishing model did not answer.")
            Log.polishing.error(
                "Term suggestions failed: \(LLMPolishingError.publicLogDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return .failed
        }
    }

    func accept(_ term: String) {
        guard add([term]) else { return }
        recordOutcome(.accepted, of: [term])
        suggestions.removeAll { $0 == term }
    }

    func acceptAll() {
        guard add(suggestions) else { return }
        recordOutcome(.accepted, of: suggestions)
        suggestions = []
    }

    func dismiss(_ term: String) {
        settings.dismissTermSuggestion(term)
        recordOutcome(.refused, of: [term])
        suggestions.removeAll { $0 == term }
    }

    // MARK: Outcome counts (LVX-11)

    /// Counts the chips on the row that no count has seen yet, as offered
    /// by `source`. Once per chip per launch: a learned chip offered again
    /// after a relaunch counts again.
    private func noteShown(source: TermSuggestionOutcomes.Source) {
        let new = suggestions.map(SpeakerTermSuggestions.key).filter { sourceByKey[$0] == nil }
        for key in new { sourceByKey[key] = source }
        record(.shown, source: source, count: new.count)
    }

    private func recordOutcome(_ event: TermSuggestionOutcomes.Event, of terms: [String]) {
        var counts: [TermSuggestionOutcomes.Source: Int] = [:]
        for term in terms {
            counts[sourceByKey[SpeakerTermSuggestions.key(term)] ?? .model, default: 0] += 1
        }
        for (source, count) in counts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            record(event, source: source, count: count)
        }
    }

    /// Adds to the saved counts in the app's defaults. Counts only: no term
    /// is saved or logged.
    private func record(_ event: TermSuggestionOutcomes.Event, source: TermSuggestionOutcomes.Source, count: Int) {
        guard count > 0 else { return }
        let defaults = settings.defaults
        var outcomes = defaults.data(forKey: Self.outcomesDefaultsKey)
            .flatMap { try? JSONDecoder().decode(TermSuggestionOutcomes.self, from: $0) }
            ?? TermSuggestionOutcomes()
        outcomes.record(event, source: source, count: count, at: now())
        if let data = try? JSONEncoder().encode(outcomes) {
            defaults.set(data, forKey: Self.outcomesDefaultsKey)
        }
        Log.polishing.info(
            "Term suggestions \(String(describing: event), privacy: .public): \(count, privacy: .public) from \(source.rawValue, privacy: .public)"
        )
    }

    /// False when the list's cap swallowed any of them: the chips stay and
    /// the row says why, instead of vanishing as if they had been added.
    /// Checked after the assignment too, whose merge with the saved list
    /// drops this copy's addition when another copy filled the list
    /// (LVX-93).
    private func add(_ terms: [String]) -> Bool {
        let updated = SpeakerTerms.sanitized(settings.polishSpeakerTerms + terms)
        let wanted = Set(terms.map(SpeakerTermSuggestions.key))
        func allKept(_ list: [String]) -> Bool {
            wanted.isSubset(of: Set(list.map(SpeakerTermSuggestions.key)))
        }
        guard allKept(updated) else {
            phase = .failed("Terms list is full.")
            return false
        }
        settings.polishSpeakerTerms = updated
        guard allKept(settings.polishSpeakerTerms) else {
            phase = .failed("Terms list is full.")
            return false
        }
        if case .failed = phase { phase = .idle }
        return true
    }
}
