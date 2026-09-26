import XCTest
@testable import localvoxtral

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

        XCTAssertNil(StopCommitCoordinator.effectiveReplacementDictionary(
            settings: viewModel.settings, appConfigStore: viewModel.appConfigStore))

        viewModel.settings.polishSpeakerTerms = ["Claude Code"]
        XCTAssertEqual(
            StopCommitCoordinator.effectiveReplacementDictionary(
                settings: viewModel.settings, appConfigStore: viewModel.appConfigStore
            )?.apply(to: "claude code from file"),
            "Claude Code from file"
        )

        viewModel.settings.replacementDictionaryEnabled = true
        XCTAssertEqual(
            StopCommitCoordinator.effectiveReplacementDictionary(
                settings: viewModel.settings, appConfigStore: viewModel.appConfigStore
            )?.apply(to: "claude code from file"),
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
