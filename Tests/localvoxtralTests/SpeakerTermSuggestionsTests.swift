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

    /// Polishing stays at the model's lowest effort; only the suggestion
    /// request thinks. `high` is the one level every hosted reasoning model
    /// accepts, and a model that does not reason still gets no field at all.
    func testOnlyTheSuggestionRequestAsksForHighReasoning() throws {
        func effort(_ polishEffort: MistralReasoningEffort, deep: Bool) throws -> String? {
            let configuration = LLMPolishingConfiguration(
                endpointURL: MistralPolishDefaults.endpoint, apiKey: "secret",
                model: "any", requestShape: .mistral, mistralReasoningEffort: polishEffort
            )
            let request = deep
                ? SpeakerTermSuggestions.request(texts: ["a"], terms: [], dismissed: [])
                : LLMPolishingRequest(inputText: "a", systemPrompt: "s", userPrompts: ["a"])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(
                with: LLMPolishingService.requestBody(request: request, configuration: configuration)
            ) as? [String: Any])
            return json["reasoning_effort"] as? String
        }

        XCTAssertEqual(try effort(.off, deep: false), "none")
        XCTAssertEqual(try effort(.low, deep: false), "low")
        XCTAssertEqual(try effort(.off, deep: true), "high")
        XCTAssertEqual(try effort(.low, deep: true), "high")
        XCTAssertNil(try effort(.omitted, deep: true))
    }

    func testASelfHostedServerIsSentNoReasoningFieldEitherWay() throws {
        let configuration = LLMPolishingConfiguration(
            endpointURL: URL(string: "http://127.0.0.1:9/v1/chat/completions")!,
            apiKey: "", model: "local"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: LLMPolishingService.requestBody(
                request: SpeakerTermSuggestions.request(texts: ["a"], terms: [], dismissed: []),
                configuration: configuration
            )
        ) as? [String: Any])
        XCTAssertNil(json["reasoning_effort"])
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
        settings: SettingsStore,
        service: Service,
        texts: [String] = ["a text", "another"],
        learned: [String] = []
    ) -> SpeakerTermSuggestionModel {
        SpeakerTermSuggestionModel(
            settings: settings,
            recentTexts: { texts },
            learnedTerms: { learned },
            service: { service }
        )
    }

    // MARK: - Learned chips

    /// The free half of the row: what the app has watched polishing fix is
    /// offered without a model call, and still only added by a click.
    func testLearnedTermsAreOfferedWithoutAskingAModel() {
        let settings = makeSettings()
        let service = Service()
        let model = makeModel(settings: settings, service: service, learned: ["Voxtral", "polishd"])

        model.refreshLearnedSuggestions()

        XCTAssertEqual(model.suggestions, ["Voxtral", "polishd"])
        XCTAssertEqual(settings.polishSpeakerTerms, [])
        XCTAssertTrue(service.requests.isEmpty, "no request, no API credits")
    }

    func testLearnedTermAlreadyKnownOrRefusedIsNotOffered() {
        let settings = makeSettings()
        settings.polishSpeakerTerms = ["Voxtral"]
        settings.dismissTermSuggestion("polishd")
        let model = makeModel(
            settings: settings, service: Service(), learned: ["Voxtral", "polishd", "Ghostty"]
        )

        model.refreshLearnedSuggestions()

        XCTAssertEqual(model.suggestions, ["Ghostty"])
    }

    /// Re-opening the pane must not resurrect a chip the user just refused,
    /// and must not duplicate one already on screen.
    func testRefreshingIsAdditiveAndSkipsWhatIsShown() {
        let settings = makeSettings()
        let model = makeModel(settings: settings, service: Service(), learned: ["Voxtral", "polishd"])

        model.refreshLearnedSuggestions()
        model.dismiss("polishd")
        model.refreshLearnedSuggestions()

        XCTAssertEqual(model.suggestions, ["Voxtral"])
    }

    /// A run takes minutes, and the pane may never have been refreshed before
    /// it started. Its completion is the app's next chance to show the free
    /// chips, so it takes it.
    func testHostedRunFillsInLearnedChipsItNeverShowed() async {
        let settings = makeSettings()
        let service = Service()
        service.reply = .success(#"["Qwen"]"#)
        let model = makeModel(settings: settings, service: service, learned: ["Voxtral"])

        await model.suggest()

        XCTAssertEqual(model.suggestions, ["Qwen", "Voxtral"])
    }

    /// A chip on screen that the user added to their list while the run was
    /// going must not come back as a suggestion when the run lands.
    func testChipAddedDuringARunIsNotReofferedWhenItEnds() async {
        let settings = makeSettings()
        let service = Service()
        service.reply = .success(#"["Qwen"]"#)
        let model = makeModel(settings: settings, service: service, learned: ["Voxtral"])
        model.refreshLearnedSuggestions()

        settings.polishSpeakerTerms = ["Voxtral"]
        await model.suggest()

        XCTAssertEqual(model.suggestions, ["Qwen"])
    }

    /// A hosted run costs minutes, so its findings lead — but the free chips
    /// the user has not acted on are not thrown away behind them.
    func testHostedRunLeadsAndKeepsUnactedLearnedChips() async {
        let settings = makeSettings()
        let service = Service()
        service.reply = .success(#"["Qwen"]"#)
        let model = makeModel(settings: settings, service: service, learned: ["Voxtral"])

        model.refreshLearnedSuggestions()
        await model.suggest()

        XCTAssertEqual(model.suggestions, ["Qwen", "Voxtral"])
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

    /// What the progress line shows, and the Stop button: the late answer of
    /// a stopped run is ignored and the row goes back to its button.
    func testARunReportsWhatItReadsSinceWhenAndCanBeStopped() async {
        let settings = makeSettings()
        let service = GatedService()
        let start = Date(timeIntervalSince1970: 1_000)
        let model = SpeakerTermSuggestionModel(
            settings: settings, recentTexts: { ["one", "two", "three"] }, service: { service },
            now: { start }
        )

        model.start()
        await service.waitUntilRequested()
        XCTAssertEqual(model.phase, .loading)
        XCTAssertEqual(model.readingCount, 3)
        XCTAssertEqual(model.startedAt, start)
        model.start()  // a second click while loading sends nothing more

        model.stop()
        XCTAssertEqual(model.phase, .idle)

        await service.release(with: #"["Qwen"]"#)
        await Task.yield()
        XCTAssertEqual(model.suggestions, [])
        XCTAssertEqual(model.phase, .idle)
        let requestCount = await service.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    /// The bundled 4B cannot do this (measured): no request is ever sent.
    func testNothingIsSentWhenSuggestionsAreUnavailable() async {
        let settings = makeSettings()
        let service = Service()
        let model = SpeakerTermSuggestionModel(
            settings: settings, recentTexts: { ["a text"] }, service: { service },
            unavailableReason: { "Needs a hosted polishing model." }
        )
        await model.suggest()
        XCTAssertEqual(model.phase, .failed("Needs a hosted polishing model."))
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
