import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A capture's words after the one polish it gets before routing (#970).
package struct QuickCapturePolish: Equatable, Sendable {
    package let text: String
    package let durationSeconds: Double

    package init(text: String, durationSeconds: Double) {
        self.text = text
        self.durationSeconds = durationSeconds
    }
}

/// Polishes a capture's words with the user's polishing model. Nil when
/// there is no polishing configuration or the request failed: the capture
/// then routes its raw words.
@MainActor
package protocol QuickCapturePolishing {
    func polish(_ text: String, vocabulary: [String]) async -> QuickCapturePolish?
}

/// The spellings a capture is polished with (#970). No project is joined
/// at capture time, so they come from every project the router offers: its
/// name, its repository's name, and its confirmed learned terms. Agent
/// proposals and terms below the confirmation bar stay out.
package enum QuickCapturePolishVocabulary {
    package static let maxTermsPerProject = 10
    package static let maxTerms = 80

    /// Every project's names first, so a long term list cannot crowd one
    /// out, then each project's confirmed terms, strongest first, up to
    /// `maxTermsPerProject`. Case-folded duplicates are dropped.
    package static func terms(projects: [QuickCaptureProject], learned: LearnedTerms) -> [String] {
        terms(
            names: projects.map { project in
                [project.name] + (project.repository?.split(separator: "/").last.map { [String($0)] } ?? [])
            },
            confirmed: projects.map { project in project.keys.flatMap { learned.confirmedTerms(projectKey: $0) } }
        )
    }

    /// The same list from each project's names and confirmed terms, both in
    /// project order: for a replay, whose projects come from a file.
    package static func terms(names: [[String]], confirmed: [[String]]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        @discardableResult
        func add(_ term: String) -> Bool {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard terms.count < maxTerms, !trimmed.isEmpty,
                  seen.insert(trimmed.caseFoldedForMatching).inserted
            else { return false }
            terms.append(trimmed)
            return true
        }
        for projectNames in names {
            for name in projectNames { add(name) }
        }
        for projectTerms in confirmed {
            var added = 0
            for term in projectTerms where added < maxTermsPerProject {
                if add(term) { added += 1 }
            }
        }
        return terms
    }
}

/// The capture's side of the polish request: the working text with the
/// matched spellings pre-applied, and the vocabulary sections for the
/// `{{replacement_dictionary}}` slot. The vocabulary goes through the same
/// matcher, merge and rendering a dictation's learned terms do, as the
/// learned source alone.
package enum QuickCapturePolishPrompt {
    package struct Prepared: Equatable, Sendable {
        package let workingText: String
        package let dictionarySection: String
    }

    /// - Parameter rendersDictionary: the prompt template has the
    ///   `{{replacement_dictionary}}` slot. Without it the matched spellings
    ///   are still pre-applied.
    package static func prepare(transcript: String, vocabulary: [String], rendersDictionary: Bool) -> Prepared {
        let outcome = LearnedTermGrounding.outcome(transcript: transcript, confirmed: vocabulary, proposals: [])
        let merged = PolishContextGrounding.merge(
            [
                PolishContextGrounding.Candidate(
                    source: .learned,
                    entries: outcome.entries,
                    isFallbackOnly: outcome.isFallbackOnly,
                    phoneticEntries: outcome.phoneticEntries,
                    verificationEntries: outcome.verificationCandidates
                ),
            ],
            maxVerificationPairs: RepoVocabularyMatcher.nominationCap(forTranscript: transcript)
        )
        let workingText = RepoVocabularyMatcher.preapplying(entries: merged.all, to: transcript)
        guard rendersDictionary else { return Prepared(workingText: workingText, dictionarySection: "") }
        let section = RepoVocabularyMatcher.appendedVerificationSection(
            base: RepoVocabularyMatcher.appendedPromptSection(
                base: "", entries: merged.entries(from: .learned), header: RepoVocabularyMatcher.learnedVocabularyHeader
            ),
            pairs: merged.verificationPairs
        )
        return Prepared(workingText: workingText, dictionarySection: section)
    }
}

/// What a capture's polish request is built from besides the words and the
/// vocabulary: the standard profile's templates as loaded, the user's About
/// you and Global terms, and the replacement file's rules when exact
/// replacement is on (nil when it is off).
package struct QuickCapturePolishInputs: Sendable {
    package var templates: LLMPromptTemplates
    package var speakerProfile: String
    package var speakerTerms: [String]
    package var replacementDictionary: ReplacementDictionary?

    package init(
        templates: LLMPromptTemplates, speakerProfile: String = "", speakerTerms: [String] = [],
        replacementDictionary: ReplacementDictionary? = nil
    ) {
        self.templates = templates
        self.speakerProfile = speakerProfile
        self.speakerTerms = speakerTerms
        self.replacementDictionary = replacementDictionary
    }
}

/// A capture's polish request: the working text, the system prompt and the
/// user messages, as the polishing endpoint gets them.
package struct QuickCapturePolishRequest: Equatable, Sendable {
    package let inputText: String
    package let systemPrompt: String
    package let userPrompts: [String]

    /// The chat messages: the system prompt when there is one, then each
    /// user message (`LLMPolishingService.requestBody`'s order).
    package var messages: [[String: String]] {
        (systemPrompt.isEmpty ? [] : [["role": "system", "content": systemPrompt]])
            + userPrompts.map { ["role": "user", "content": $0] }
    }
}

extension QuickCapturePolishPrompt {
    /// The whole request, as a dictation's polish assembles its own: the
    /// replacement rules and the casing of the user's terms applied first,
    /// then the vocabulary matched, into the profile's templates with the
    /// reference guide and About you.
    package static func request(
        transcript: String, vocabulary: [String], inputs: QuickCapturePolishInputs
    ) -> QuickCapturePolishRequest {
        let templates = inputs.templates.withReferenceGuide()
            .withSpeakerProfile(inputs.speakerProfile, terms: inputs.speakerTerms)
        let rules = (inputs.replacementDictionary ?? ReplacementDictionary(entries: []))
            .adding(speakerTerms: inputs.speakerTerms)
        let replaced = rules.entries.isEmpty ? transcript : rules.apply(to: transcript)
        let prepared = prepare(
            transcript: replaced, vocabulary: vocabulary, rendersDictionary: templates.supportsReplacementDictionary
        )
        return QuickCapturePolishRequest(
            inputText: prepared.workingText,
            systemPrompt: templates.systemContent,
            userPrompts: templates.renderedUserPrompts(
                inputText: prepared.workingText, replacementDictionary: prepared.dictionarySection
            )
        )
    }
}

/// Sends a capture's polish request to any `chat/completions` endpoint, for
/// the replay (`scripts/linux/quick-capture-replay.sh --polish-url`). The app
/// sends the same request through `LLMPolishingService`.
@MainActor
package final class QuickCaptureChatPolisher: QuickCapturePolishing {
    package typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let endpoint: URL
    private let apiKey: String
    private let model: String
    private let extraBody: [String: any Sendable]
    private let inputs: QuickCapturePolishInputs
    private let send: Send
    /// The last failure, for the replay to print.
    package private(set) var lastError: (any Error)?

    /// - Parameter extraBody: fields merged into the body last, e.g. a
    ///   reasoning effort or sampling the endpoint needs.
    package init(
        endpoint: URL, apiKey: String, model: String, extraBody: [String: any Sendable] = [:],
        inputs: QuickCapturePolishInputs,
        send: @escaping Send = { try await URLSession.shared.data(for: $0) }
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.extraBody = extraBody
        self.inputs = inputs
        self.send = send
    }

    /// The request's JSON body: the model, the messages, the app's default
    /// temperature, then `extraBody`.
    package static func body(
        model: String, request: QuickCapturePolishRequest, extraBody: [String: any Sendable]
    ) -> Data {
        var body: [String: Any] = ["model": model, "messages": request.messages, "temperature": 0.3]
        for (key, value) in extraBody { body[key] = value }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    package func polish(_ text: String, vocabulary: [String]) async -> QuickCapturePolish? {
        let request = QuickCapturePolishPrompt.request(transcript: text, vocabulary: vocabulary, inputs: inputs)
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 60)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        urlRequest.httpBody = Self.body(model: model, request: request, extraBody: extraBody)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (data, response) = try await send(urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw QuickCaptureChatRouting.Failure.http(status: status) }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = QuickCaptureChatRouting.text(ofContent: message["content"]),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw QuickCaptureChatRouting.Failure.malformedResponse }
            let elapsed = clock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return QuickCapturePolish(text: content.trimmingCharacters(in: .whitespacesAndNewlines), durationSeconds: seconds)
        } catch {
            lastError = error
            return nil
        }
    }
}
