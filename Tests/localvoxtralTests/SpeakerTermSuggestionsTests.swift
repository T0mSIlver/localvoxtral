import XCTest
@testable import localvoxtral

final class SpeakerTermSuggestionsTests: XCTestCase {
    func testKeyIgnoresCaseSpacingAndPunctuation() {
        let keys = ["SessionStart", "session start", "Session-Start", " SESSION_START "]
            .map(SpeakerTermSuggestions.key)
        XCTAssertEqual(Set(keys), ["sessionstart"])
    }

    func testParseReadsStringsObjectsAndFencedJSON() {
        XCTAssertEqual(SpeakerTermSuggestions.parse(#"["Qwen", "MCP"]"#), ["Qwen", "MCP"])
        XCTAssertEqual(
            SpeakerTermSuggestions.parse("```json\n[{\"term\": \"Qwen\", \"texts\": 7}, 3, \"MCP\"]\n```"),
            ["Qwen", "MCP"]
        )
        XCTAssertEqual(SpeakerTermSuggestions.parse("I could not find anything."), [])
        XCTAssertEqual(SpeakerTermSuggestions.parse("[not json"), [])
        XCTAssertEqual(
            SpeakerTermSuggestions.parse("<think>maybe [x] or [1]</think> [\"Qwen\"] (see [1])"),
            ["Qwen"]
        )
    }

    /// The model is TOLD what was refused, but this filter is the guarantee.
    func testRefusedAndKnownTermsNeverComeBackWhateverTheModelReturns() {
        XCTAssertEqual(
            SpeakerTermSuggestions.filtered(
                ["session start", "Qwen", "qwen", "MCP", "Mistral"],
                terms: ["Mistral"],
                dismissed: ["SessionStart"]
            ),
            ["Qwen", "MCP"]
        )
    }

    /// A model that lists everything front-loads what the user already has;
    /// the 80-term cap must be spent on what is new.
    func testKnownTermsDoNotCrowdOutNewOnesPastTheCap() {
        let known = (0..<SpeakerTerms.maxTerms).map { "Known\($0)x" }
        XCTAssertEqual(
            SpeakerTermSuggestions.filtered(known + ["Qwen"], terms: known, dismissed: []),
            ["Qwen"]
        )
    }

    func testTheKnownAndRefusedListsSpendTheRequestBudget() {
        let text = String(repeating: "a", count: 100)
        XCTAssertEqual(
            SpeakerTermSuggestions.selected(
                [text, text], reserved: SpeakerTermSuggestions.maxRequestCharacters - 150
            ).count,
            1
        )
    }

    /// Counting checks the model's frequency claim without deciding what a
    /// name is: a recovered spelling that occurs in no text stays in.
    func testRankingPutsVerifiedTermsFirstAndDropsNothing() {
        let texts = [
            "we serve coin 3.6 behind the MCP server", "the mcp tools", "MCP again, with Glossator",
            "Kuen is the model", "open localvoxtral.js",
        ]
        XCTAssertEqual(
            SpeakerTermSuggestions.ranked(["localvoxtral.js", "Qwen", "MCP", "Glossator"], texts: texts),
            ["MCP", "localvoxtral.js", "Qwen", "Glossator"]
        )
    }

    func testSelectionKeepsNewestWithinTheRequestBudget() {
        let long = String(repeating: "a", count: SpeakerTermSuggestions.maxRequestCharacters)
        XCTAssertEqual(SpeakerTermSuggestions.selected(["  newest ", "", long, "older"]), ["newest"])
        XCTAssertEqual(
            SpeakerTermSuggestions.selected(Array(repeating: "x", count: 500)).count,
            SpeakerTermSuggestions.maxDictations
        )
    }

    /// polishd checkpoints every message but the last; a lone user message
    /// leaves the two dictation profiles' prompt-cache slots alone.
    @MainActor
    func testTheRequestGoesOutAsOneUserMessageWithNoSystemMessage() throws {
        let settings = SettingsStore(
            defaults: UserDefaults(suiteName: "localvoxtral.SuggestBody.\(UUID().uuidString)")!,
            environment: [:], secretStore: InMemorySecretStore()
        )
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "http://127.0.0.1:9/v1/chat/completions"
        let configuration = try XCTUnwrap(settings.llmPolishingConfiguration)

        let data = try LLMPolishingService.requestBody(
            request: SpeakerTermSuggestions.request(texts: ["a"], terms: [], dismissed: []),
            configuration: configuration
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])

        XCTAssertEqual(messages.map { $0["role"] }, ["user"])
    }

    func testRequestNamesKnownAndRefusedTermsAndAllowsALongWait() {
        let request = SpeakerTermSuggestions.request(
            texts: ["first", "second"], terms: ["Qwen"], dismissed: ["SessionStart"]
        )
        XCTAssertEqual(
            request.userPrompts,
            [SpeakerTermSuggestions.instructions + "\n\n" + """
            Already known (do not list): Qwen

            Refused by the user (do not list): SessionStart

            [text 1]
            first

            [text 2]
            second
            """]
        )
        XCTAssertEqual(request.timeoutSeconds, SpeakerTermSuggestions.timeoutSeconds)
        // No system message: polishd would checkpoint it and evict a
        // dictation profile's prompt-cache slot.
        XCTAssertEqual(request.systemPrompt, "")
    }
}

@MainActor
final class SpeakerTermSuggestionModelTests: XCTestCase {
    private final class Service: LLMPolishingServicing, @unchecked Sendable {
        var reply: Result<String, Error> = .success("[]")
        private(set) var requests: [LLMPolishingRequest] = []
        func polish(
            request: LLMPolishingRequest, configuration: LLMPolishingConfiguration
        ) async throws -> LLMPolishingResult {
            requests.append(request)
            return LLMPolishingResult(
                rawText: request.inputText, polishedText: try reply.get(), durationSeconds: 0
            )
        }
    }

    private func makeSettings() -> SettingsStore {
        let suiteName = "localvoxtral.SpeakerTermSuggestionModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(
            defaults: defaults, environment: [:], secretStore: InMemorySecretStore()
        )
        settings.llmPolishingEnabled = true
        settings.llmPolishingEndpointURL = "http://127.0.0.1:9/v1/chat/completions"
        return settings
    }

    private func makeModel(
        settings: SettingsStore, service: Service, texts: [String] = ["a text", "another"]
    ) -> SpeakerTermSuggestionModel {
        SpeakerTermSuggestionModel(
            settings: settings, recentTexts: { texts }, service: { service }
        )
    }

    func testNothingIsAddedWithoutAClick() async {
        let settings = makeSettings()
        let service = Service()
        service.reply = .success(#"["Qwen", "MCP"]"#)
        let model = makeModel(settings: settings, service: service)

        await model.suggest()

        XCTAssertEqual(model.suggestions, ["Qwen", "MCP"])
        XCTAssertEqual(settings.polishSpeakerTerms, [])

        model.accept("Qwen")
        XCTAssertEqual(settings.polishSpeakerTerms, ["Qwen"])
        XCTAssertEqual(model.suggestions, ["MCP"])
    }

    func testDismissedSuggestionNeverReturnsEvenIfTheModelRepeatsIt() async {
        let settings = makeSettings()
        let service = Service()
        service.reply = .success(#"["SessionStart", "MCP"]"#)
        let model = makeModel(settings: settings, service: service)

        await model.suggest()
        model.dismiss("SessionStart")
        XCTAssertEqual(model.suggestions, ["MCP"])

        service.reply = .success(#"["session start", "Session-Start", "MCP"]"#)
        await model.suggest()

        XCTAssertEqual(model.suggestions, ["MCP"])
        XCTAssertTrue(service.requests.last?.userPrompts.first?
            .contains("Refused by the user (do not list): SessionStart") ?? false)
    }

    func testAddingARefusedTermByHandForgetsTheRefusal() {
        let settings = makeSettings()
        settings.dismissTermSuggestion("SessionStart")
        settings.dismissTermSuggestion("session start")
        XCTAssertEqual(settings.polishDismissedTermSuggestions, ["SessionStart"])

        settings.polishSpeakerTerms = ["Session Start"]
        XCTAssertEqual(settings.polishDismissedTermSuggestions, [])
    }

    func testAddAllMovesEverySuggestionIntoTheTerms() async {
        let settings = makeSettings()
        let service = Service()
        service.reply = .success(#"["Qwen", "MCP"]"#)
        let model = makeModel(settings: settings, service: service)

        await model.suggest()
        model.acceptAll()

        XCTAssertEqual(settings.polishSpeakerTerms, ["Qwen", "MCP"])
        XCTAssertEqual(model.suggestions, [])
    }

    func testFailureAndEmptyHistoryAreReportedInOneShortSentence() async {
        let settings = makeSettings()
        let service = Service()
        service.reply = .failure(LLMPolishingError.invalidResponse)
        let failing = makeModel(settings: settings, service: service)
        await failing.suggest()
        XCTAssertEqual(failing.phase, .failed("The polishing model did not answer."))

        let empty = makeModel(settings: settings, service: service, texts: [])
        await empty.suggest()
        XCTAssertEqual(empty.phase, .failed("No dictations to read yet."))
        XCTAssertEqual(service.requests.count, 1)
    }

    func testAFullTermsListKeepsTheChipAndSaysWhy() async {
        let settings = makeSettings()
        settings.polishSpeakerTerms = (0..<SpeakerTerms.maxTerms).map { "Known\($0)x" }
        let service = Service()
        service.reply = .success(#"["Qwen"]"#)
        let model = makeModel(settings: settings, service: service)

        await model.suggest()
        model.accept("Qwen")

        XCTAssertEqual(model.suggestions, ["Qwen"])
        XCTAssertEqual(model.phase, .failed("Terms list is full."))
        XCTAssertFalse(settings.polishSpeakerTerms.contains("Qwen"))
    }

    func testTheOldestRefusalIsTheOneTheCapDrops() {
        let settings = makeSettings()
        for index in 0...SpeakerTermSuggestions.maxDismissed {
            settings.dismissTermSuggestion("Refused\(index)x")
        }
        XCTAssertEqual(
            settings.polishDismissedTermSuggestions.count, SpeakerTermSuggestions.maxDismissed)
        XCTAssertEqual(settings.polishDismissedTermSuggestions.first, "Refused1x")
    }

    /// The bundled helper generates one request at a time: a dictation must
    /// not wait behind a suggestion run.
    func testADictationStopsARunInFlightAndItsLateAnswerIsIgnored() async {
        let settings = makeSettings()
        let service = GatedService()
        let model = SpeakerTermSuggestionModel(
            settings: settings, recentTexts: { ["a text"] }, service: { service }
        )

        model.start()
        await service.waitUntilRequested()
        XCTAssertEqual(model.phase, .loading)
        model.start()  // a second click while loading does nothing

        model.cancelForDictation()
        XCTAssertEqual(model.phase, .failed("Stopped: a dictation started."))

        await service.release(with: #"["Qwen"]"#)
        await Task.yield()
        XCTAssertEqual(model.suggestions, [])
        XCTAssertEqual(model.phase, .failed("Stopped: a dictation started."))
        let requestCount = await service.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testSuggestRefusesWhileDictating() async {
        let settings = makeSettings()
        let service = Service()
        let model = SpeakerTermSuggestionModel(
            settings: settings, recentTexts: { ["a text"] }, service: { service },
            isDictating: { true }
        )
        await model.suggest()
        XCTAssertEqual(model.phase, .failed("Finish dictating first."))
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testShowsAtMostTwelve() async {
        let settings = makeSettings()
        let service = Service()
        let many = (0..<40).map { "Term\($0)x" }
        service.reply = .success(String(data: try! JSONSerialization.data(withJSONObject: many), encoding: .utf8)!)
        let model = makeModel(settings: settings, service: service)

        await model.suggest()
        XCTAssertEqual(model.suggestions.count, SpeakerTermSuggestions.maxShown)
    }
}

/// Holds the reply until the test releases it; continuations, no clock.
private actor GatedService: LLMPolishingServicing {
    private(set) var requestCount = 0
    private var requested: CheckedContinuation<Void, Never>?
    private var reply: CheckedContinuation<String, Never>?

    func polish(
        request: LLMPolishingRequest, configuration: LLMPolishingConfiguration
    ) async throws -> LLMPolishingResult {
        requestCount += 1
        requested?.resume()
        requested = nil
        let text = await withCheckedContinuation { reply = $0 }
        return LLMPolishingResult(rawText: "", polishedText: text, durationSeconds: 0)
    }

    func waitUntilRequested() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { requested = $0 }
    }

    func release(with text: String) {
        reply?.resume(returning: text)
        reply = nil
    }
}
