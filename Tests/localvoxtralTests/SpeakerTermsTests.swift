import XCTest
@testable import localvoxtral

final class SpeakerTermsTests: XCTestCase {
    func testSanitizedTrimsDedupesCaseInsensitivelyAndKeepsFirstSpelling() {
        XCTAssertEqual(
            SpeakerTerms.sanitized(["  Qwen ", "qwen", "Claude   Code", "", "a\nb", "vLLM"]),
            ["Qwen", "Claude Code", "ab", "vLLM"]
        )
    }

    func testSanitizedDropsOverlongTermsAndCapsTheList() {
        let long = String(repeating: "x", count: SpeakerTerms.maxTermCharacters + 1)
        XCTAssertEqual(SpeakerTerms.sanitized([long, "ok"]), ["ok"])
        XCTAssertEqual(
            SpeakerTerms.sanitized((0..<500).map { "term\($0)" }).count,
            SpeakerTerms.maxTerms
        )
    }

    func testOneSubmissionAddsEveryCommaSeparatedTerm() {
        XCTAssertEqual(
            SpeakerTerms.adding("Claude Code, vLLM,qwen", to: ["Qwen"]),
            ["Qwen", "Claude Code", "vLLM"]
        )
    }

    /// The user types the right spelling only; the rule is derived from it.
    func testTermsFixCasingAndSpacingWithoutAModel() {
        let dictionary = ReplacementDictionary(entries: [])
            .adding(speakerTerms: ["Claude Code", "vLLM", "GitHub"])
        XCTAssertEqual(
            dictionary.apply(to: "ask claude  code to push the vllm patch to github"),
            "ask Claude Code to push the vLLM patch to GitHub"
        )
    }

    /// "Work" and "Vibe" are products AND ordinary words. Nothing without a
    /// model can tell them apart, so they get no rule and reach the prompt only.
    func testPlainCapitalizedWordGetsNoRule() {
        XCTAssertTrue(SpeakerTerms.replacementEntries(for: ["Work", "Vibe", "Qwen"]).isEmpty)
        XCTAssertEqual(
            ReplacementDictionary(entries: []).adding(speakerTerms: ["Work"])
                .apply(to: "the work is done"),
            "the work is done"
        )
    }

    func testHandWrittenDictionaryRuleWinsOverTheTermRule() {
        let dictionary = ReplacementDictionary(entries: [
            ReplacementEntry(replaceWith: "Claude Code CLI", matches: ["claude code"]),
        ]).adding(speakerTerms: ["Claude Code"])
        XCTAssertEqual(dictionary.apply(to: "open claude code"), "open Claude Code CLI")
    }

    func testImportTakesTheDictionarySpellingsNotTheMishearings() {
        let dictionary = ReplacementDictionary(entries: [
            ReplacementEntry(replaceWith: "Qwen", matches: ["coin", "kuen"]),
            ReplacementEntry(replaceWith: "Claude Code", matches: ["cloud code"]),
            ReplacementEntry(replaceWith: "qwen", matches: ["q n"]),
        ])
        XCTAssertEqual(SpeakerTerms.migrated(from: dictionary), ["Qwen", "Claude Code"])
    }

    /// Asserted on the correction itself: a no-op correction leaves the text
    /// unchanged, so comparing strings could not see it.
    func testLiveCorrectorEmitsNoCorrectionForATermThatIsAlreadyRight() {
        let dictionary = ReplacementDictionary(entries: []).adding(speakerTerms: ["Claude Code"])

        var right = LiveReplacementCorrector(dictionary: dictionary)
        right.recordInsertedText("open Claude Code now")
        XCTAssertNil(right.nextCompletedBoundaryCorrection())

        var wrong = LiveReplacementCorrector(dictionary: dictionary)
        wrong.recordInsertedText("open claude code now")
        XCTAssertEqual(wrong.nextCompletedBoundaryCorrection()?.replacementText, "Claude Code ")
    }

    /// "US" and "IT" are all capitals: a rule would uppercase "us" and "it".
    func testAcronymGetsNoRule() {
        XCTAssertTrue(SpeakerTerms.replacementEntries(for: ["US", "IT", "GLM", "MCP"]).isEmpty)
        XCTAssertEqual(
            ReplacementDictionary(entries: []).adding(speakerTerms: ["US", "IT"])
                .apply(to: "give it to us tomorrow"),
            "give it to us tomorrow"
        )
        XCTAssertEqual(
            SpeakerTerms.replacementEntries(for: ["vLLM", "iPhone", "GitHub"]).map(\.replaceWith),
            ["vLLM", "iPhone", "GitHub"]
        )
    }
}

@MainActor
final class SpeakerTermsImportTests: XCTestCase {
    private final class Store: AppConfigServing {
        var dictionary: ReplacementDictionary?
        func configDirectoryURL() -> URL { FileManager.default.temporaryDirectory }
        func loadReplacementDictionary() -> ReplacementDictionary {
            dictionary ?? ReplacementDictionary(entries: [])
        }
        func loadReplacementDictionaryIfReadable() -> ReplacementDictionary? { dictionary }
        func loadLLMPromptTemplates() -> LLMPromptTemplates {
            LLMPromptTemplates(systemContent: "system", userContent: "{{input_text}}")
        }
        func loadTerminalAppBundleIDs() -> [String] { [] }
    }

    private func makeViewModel(store: Store) -> DictationViewModel {
        let suiteName = "localvoxtral.SpeakerTermsImportTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = DictationViewModel(
            settings: SettingsStore(
                defaults: defaults, environment: [:], secretStore: InMemorySecretStore()
            ),
            startRuntimeServices: false
        )
        viewModel.appConfigStore = store
        return viewModel
    }

    func testImportRunsOnceAndAnEmptiedListStaysEmpty() {
        let store = Store()
        store.dictionary = ReplacementDictionary(entries: [
            ReplacementEntry(replaceWith: "Qwen", matches: ["coin"]),
        ])
        let viewModel = makeViewModel(store: store)

        viewModel.importSpeakerTermsFromReplacementDictionary()
        XCTAssertEqual(viewModel.settings.polishSpeakerTerms, ["Qwen"])

        viewModel.settings.polishSpeakerTerms = []
        viewModel.importSpeakerTermsFromReplacementDictionary()
        XCTAssertEqual(viewModel.settings.polishSpeakerTerms, [])
    }

    /// What the Live Auto-Paste gate and the overlay commit both read: terms
    /// apply with the legacy dictionary toggle OFF (its default), and with
    /// nothing to apply there is no dictionary at all, so no hold-back.
    func testTermsApplyWithTheDictionaryToggleOff() {
        let store = Store()
        store.dictionary = ReplacementDictionary(entries: [
            ReplacementEntry(replaceWith: "FROM FILE", matches: ["from file"]),
        ])
        let viewModel = makeViewModel(store: store)
        viewModel.settings.replacementDictionaryEnabled = false

        XCTAssertNil(viewModel.loadEffectiveReplacementDictionary())

        viewModel.settings.polishSpeakerTerms = ["Claude Code"]
        XCTAssertEqual(
            viewModel.loadEffectiveReplacementDictionary()?.apply(to: "claude code from file"),
            "Claude Code from file"
        )

        viewModel.settings.replacementDictionaryEnabled = true
        XCTAssertEqual(
            viewModel.loadEffectiveReplacementDictionary()?.apply(to: "claude code from file"),
            "Claude Code FROM FILE"
        )
    }

    /// A TOML error on the first launch must not burn the one import.
    func testUnreadableDictionaryPostponesTheImport() {
        let store = Store()
        let viewModel = makeViewModel(store: store)

        viewModel.importSpeakerTermsFromReplacementDictionary()
        XCTAssertFalse(viewModel.settings.hasStoredPolishSpeakerTerms)

        store.dictionary = ReplacementDictionary(entries: [
            ReplacementEntry(replaceWith: "Claude Code", matches: ["cloud code"]),
        ])
        viewModel.importSpeakerTermsFromReplacementDictionary()
        XCTAssertEqual(viewModel.settings.polishSpeakerTerms, ["Claude Code"])
    }
}

final class SpeakerTermsPromptTests: XCTestCase {
    private let templates = LLMPromptTemplates(
        systemContent: "SYSTEM",
        userContent: "{{replacement_dictionary}}\n{{input_text}}"
    )

    func testTermsAloneStillProduceTheAboutYouBlock() {
        XCTAssertEqual(
            templates.withSpeakerProfile("", terms: ["Qwen", "Claude Code"]).systemContent,
            "SYSTEM\n\n\(LLMPromptTemplates.speakerProfileHeader)\n"
                + "Names and terms they use: Qwen, Claude Code\n"
        )
    }

    func testProfileComesBeforeTheTerms() {
        XCTAssertEqual(
            templates.withSpeakerProfile("I run inference.", terms: ["vLLM"]).systemContent,
            "SYSTEM\n\n\(LLMPromptTemplates.speakerProfileHeader)\n"
                + "I run inference.\nNames and terms they use: vLLM\n"
        )
    }

    func testNothingTypedLeavesThePromptByteExact() {
        XCTAssertEqual(templates.withSpeakerProfile(" ", terms: ["", "  "]), templates)
    }
}
