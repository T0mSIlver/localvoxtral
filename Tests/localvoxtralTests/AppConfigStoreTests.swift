import Foundation
import XCTest
@testable import localvoxtral

final class AppConfigStoreTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testConfigBootstrapCreatesExpectedFiles() throws {
        let directory = makeTemporaryConfigDirectory()
        let store = AppConfigStore(configDirectoryOverride: directory)

        let configDirectory = store.configDirectoryURL()

        XCTAssertTrue(FileManager.default.fileExists(atPath: configDirectory.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: configDirectory.appendingPathComponent("replacement_dictionary.toml").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: configDirectory.appendingPathComponent("llm_system_prompt.toml").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: configDirectory.appendingPathComponent("llm_user_prompt.toml").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: configDirectory.appendingPathComponent("terminal_apps.toml").path
            )
        )

        let templates = store.loadLLMPromptTemplates()
        XCTAssertFalse(templates.systemContent.trimmed.isEmpty)
        XCTAssertFalse(templates.userContent.trimmed.isEmpty)
        // Bundled terminal_apps template ships an empty list.
        XCTAssertEqual(store.loadTerminalAppBundleIDs(), [])
    }

    func testTerminalAppsConfigParsesBundleIDs() throws {
        let directory = makeTemporaryConfigDirectory()
        try write(
            """
            # apps that embed a terminal
            bundle_ids = [
                "com.cmuxterm.app", # agent manager
                "com.microsoft.VSCode",
                "  ",
            ]
            """,
            named: "terminal_apps.toml",
            in: directory
        )
        let store = AppConfigStore(configDirectoryOverride: directory)

        XCTAssertEqual(
            store.loadTerminalAppBundleIDs(),
            ["com.cmuxterm.app", "com.microsoft.VSCode"]
        )
    }

    func testInvalidTerminalAppsConfigFallsBackToEmptyList() throws {
        let directory = makeTemporaryConfigDirectory()
        try write(
            """
            bundle_ids = ["com.cmuxterm.app"
            """,
            named: "terminal_apps.toml",
            in: directory
        )
        let store = AppConfigStore(configDirectoryOverride: directory)

        XCTAssertEqual(store.loadTerminalAppBundleIDs(), [])
    }

    func testTerminalAppsConfigRejectsUnsupportedKeys() throws {
        let directory = makeTemporaryConfigDirectory()
        try write(
            """
            apps = ["com.cmuxterm.app"]
            """,
            named: "terminal_apps.toml",
            in: directory
        )
        let store = AppConfigStore(configDirectoryOverride: directory)

        XCTAssertEqual(store.loadTerminalAppBundleIDs(), [])
    }

    func testInvalidReplacementDictionaryFallsBackToBundledDefault() throws {
        let fallbackStore = AppConfigStore(configDirectoryOverride: makeTemporaryConfigDirectory())
        let fallbackDictionary = fallbackStore.loadReplacementDictionary()

        let directory = makeTemporaryConfigDirectory()
        try write(
            """
            [[replacement]]
            replace_with = "PostgreSQL"
            matches = ["postgres"
            """,
            named: "replacement_dictionary.toml",
            in: directory
        )
        let store = AppConfigStore(configDirectoryOverride: directory)

        let dictionary = store.loadReplacementDictionary()

        XCTAssertEqual(dictionary, fallbackDictionary)
    }

    func testInvalidPromptTemplateFallsBackToBundledDefault() throws {
        let fallbackStore = AppConfigStore(configDirectoryOverride: makeTemporaryConfigDirectory())
        let fallbackTemplates = fallbackStore.loadLLMPromptTemplates()

        let directory = makeTemporaryConfigDirectory()
        try write(
            #"content = "unterminated"#,
            named: "llm_user_prompt.toml",
            in: directory
        )
        let store = AppConfigStore(configDirectoryOverride: directory)

        let templates = store.loadLLMPromptTemplates()

        XCTAssertEqual(templates.systemContent, fallbackTemplates.systemContent)
        XCTAssertEqual(templates.userContent, fallbackTemplates.userContent)
    }

    func testUserPromptMissingInputTextFallsBackToBundledDefault() throws {
        let fallbackStore = AppConfigStore(configDirectoryOverride: makeTemporaryConfigDirectory())
        let fallbackTemplates = fallbackStore.loadLLMPromptTemplates()

        let directory = makeTemporaryConfigDirectory()
        try write(
            """
            content = "Rules only: {{replacement_dictionary}}"
            """,
            named: "llm_user_prompt.toml",
            in: directory
        )

        let store = AppConfigStore(configDirectoryOverride: directory)
        let templates = store.loadLLMPromptTemplates()

        XCTAssertEqual(templates.userContent, fallbackTemplates.userContent)
    }

    func testUserPromptWithUnsupportedPlaceholderFallsBackToBundledDefault() throws {
        let fallbackStore = AppConfigStore(configDirectoryOverride: makeTemporaryConfigDirectory())
        let fallbackTemplates = fallbackStore.loadLLMPromptTemplates()

        let directory = makeTemporaryConfigDirectory()
        try write(
            """
            content = "{{input_text}}\n{{original_text}}"
            """,
            named: "llm_user_prompt.toml",
            in: directory
        )

        let store = AppConfigStore(configDirectoryOverride: directory)
        let templates = store.loadLLMPromptTemplates()

        XCTAssertEqual(templates.userContent, fallbackTemplates.userContent)
    }

    func testCustomPromptTemplatesOverrideBundledDefaults() throws {
        let directory = makeTemporaryConfigDirectory()
        try write(
            """
            content = "system override"
            """,
            named: "llm_system_prompt.toml",
            in: directory
        )
        try write(
            """
            content = \"\"\"
            User override:
            {{input_text}}
            \"\"\"
            """,
            named: "llm_user_prompt.toml",
            in: directory
        )

        let store = AppConfigStore(configDirectoryOverride: directory)
        let templates = store.loadLLMPromptTemplates()

        XCTAssertEqual(templates.systemContent, "system override")
        XCTAssertEqual(templates.userContent, "User override:\n{{input_text}}\n")
    }

    // MARK: - Agent-profile prompt templates

    func testAgentProfileSeedsAndLoadsAgentTemplatesFromBundle() throws {
        let directory = makeTemporaryConfigDirectory()
        let store = AppConfigStore(configDirectoryOverride: directory)

        let agentTemplates = store.loadLLMPromptTemplates(profile: .agent)
        let standardTemplates = store.loadLLMPromptTemplates()

        // Bootstrapped the agent files alongside the standard ones.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("llm_system_prompt_agent.toml").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("llm_user_prompt_agent.toml").path
            )
        )

        // Agent templates are distinct from standard and carry agent duties.
        XCTAssertNotEqual(agentTemplates.systemContent, standardTemplates.systemContent)
        XCTAssertNotEqual(agentTemplates.userContent, standardTemplates.userContent)
        XCTAssertTrue(agentTemplates.systemContent.contains("--"))
        XCTAssertTrue(agentTemplates.userContent.contains("{{input_text}}"))
    }

    func testStandardProfileReturnsStandardTemplates() throws {
        let directory = makeTemporaryConfigDirectory()
        let store = AppConfigStore(configDirectoryOverride: directory)

        XCTAssertEqual(
            store.loadLLMPromptTemplates(profile: .standard),
            store.loadLLMPromptTemplates()
        )
    }

    func testCorruptAgentUserPromptFallsBackToStandardTemplates() throws {
        let fallbackStore = AppConfigStore(configDirectoryOverride: makeTemporaryConfigDirectory())
        let standardTemplates = fallbackStore.loadLLMPromptTemplates()

        let directory = makeTemporaryConfigDirectory()
        try write(
            #"content = "unterminated"#,
            named: "llm_user_prompt_agent.toml",
            in: directory
        )
        let store = AppConfigStore(configDirectoryOverride: directory)

        XCTAssertEqual(store.loadLLMPromptTemplates(profile: .agent), standardTemplates)
    }

    func testAgentUserPromptMissingInputTextFallsBackToStandardTemplates() throws {
        let fallbackStore = AppConfigStore(configDirectoryOverride: makeTemporaryConfigDirectory())
        let standardTemplates = fallbackStore.loadLLMPromptTemplates()

        let directory = makeTemporaryConfigDirectory()
        try write(
            """
            content = "Agent rules only: {{replacement_dictionary}}"
            """,
            named: "llm_user_prompt_agent.toml",
            in: directory
        )
        let store = AppConfigStore(configDirectoryOverride: directory)

        // Placeholder validation fails -> the whole agent profile falls back to
        // standard (never leaves polish promptless).
        XCTAssertEqual(store.loadLLMPromptTemplates(profile: .agent), standardTemplates)
    }

    func testReplacementDictionary_singleWordReplacement() throws {
        let store = try makeStore(
            replacementDictionary: """
            [[replacement]]
            replace_with = "PostgreSQL"
            matches = ["postgres"]
            """
        )

        let dictionary = store.loadReplacementDictionary()

        XCTAssertEqual(dictionary.apply(to: "postgres is up"), "PostgreSQL is up")
    }

    func testReplacementDictionary_multiWordReplacement() throws {
        let store = try makeStore(
            replacementDictionary: """
            [[replacement]]
            replace_with = "localvoxtral"
            matches = ["local voxtral"]
            """
        )

        let dictionary = store.loadReplacementDictionary()

        XCTAssertEqual(
            dictionary.apply(to: "I use local    voxtral every day"),
            "I use localvoxtral every day"
        )
    }

    func testReplacementDictionary_adjacentPunctuationStillMatches() throws {
        let store = try makeStore(
            replacementDictionary: """
            [[replacement]]
            replace_with = "PostgreSQL"
            matches = ["postgres"]
            """
        )

        let dictionary = store.loadReplacementDictionary()

        XCTAssertEqual(dictionary.apply(to: "(postgres), postgres."), "(PostgreSQL), PostgreSQL.")
    }

    func testReplacementDictionary_doesNotReplaceInsideLargerWords() throws {
        let store = try makeStore(
            replacementDictionary: """
            [[replacement]]
            replace_with = "PostgreSQL"
            matches = ["postgres"]
            """
        )

        let dictionary = store.loadReplacementDictionary()

        XCTAssertEqual(
            dictionary.apply(to: "postgresql postgres postgresx"),
            "postgresql PostgreSQL postgresx"
        )
    }

    func testReplacementDictionary_longestMatchWins() throws {
        let store = try makeStore(
            replacementDictionary: """
            [[replacement]]
            replace_with = "LocalVoxtral App"
            matches = ["local voxtral app"]

            [[replacement]]
            replace_with = "localvoxtral"
            matches = ["local voxtral"]
            """
        )

        let dictionary = store.loadReplacementDictionary()

        XCTAssertEqual(dictionary.apply(to: "local voxtral app"), "LocalVoxtral App")
    }

    func testReplacementDictionary_earlierFileOrderWinsOnEqualLengthTie() throws {
        let store = try makeStore(
            replacementDictionary: """
            [[replacement]]
            replace_with = "Alpha"
            matches = ["foo bar"]

            [[replacement]]
            replace_with = "Beta"
            matches = ["foo bar"]
            """
        )

        let dictionary = store.loadReplacementDictionary()

        XCTAssertEqual(dictionary.apply(to: "foo bar"), "Alpha")
    }

    func testRenderedUserPromptReplacesSupportedPlaceholders() {
        let templates = LLMPromptTemplates(
            systemContent: "ignored",
            userContent: "{{replacement_dictionary}}\n{{input_text}}"
        )

        let rendered = templates.renderedUserPrompt(
            inputText: "Original transcript:\nraw",
            replacementDictionary: "Replacement dictionary:\n- PostgreSQL: postgres"
        )

        XCTAssertEqual(
            rendered,
            """
            Replacement dictionary:
            - PostgreSQL: postgres
            Original transcript:
            raw
            """
        )
    }

    func testRenderedUserPromptsSplitsAtFirstPlaceholder() {
        let templates = LLMPromptTemplates(
            systemContent: "ignored",
            userContent: """
            Static guidance.

            {{replacement_dictionary}}
            Working text:
            {{input_text}}
            """
        )

        let rendered = templates.renderedUserPrompts(
            inputText: "PostgreSQL rocks",
            replacementDictionary: "Replacement dictionary:\n- PostgreSQL: postgres"
        )

        XCTAssertEqual(
            rendered,
            [
                "Static guidance.\n\n",
                """
                Replacement dictionary:
                - PostgreSQL: postgres
                Working text:
                PostgreSQL rocks
                """,
            ]
        )
    }

    /// An EMPTY dictionary must not leave its template line behind as a hole
    /// of blank lines between the context blocks and `Working text:` (field
    /// report 2026-07-21: the rendered message began with two blank lines).
    /// The placeholder and one following blank line vanish together; a
    /// non-empty dictionary renders byte-identically to before.
    func testEmptyReplacementDictionaryLeavesNoBlankHole() {
        let templates = LLMPromptTemplates(
            systemContent: "ignored",
            userContent: """
            Static guidance.

            {{replacement_dictionary}}

            Working text:
            {{input_text}}

            Return only the final corrected text.
            """
        )

        let rendered = templates.renderedUserPrompts(
            inputText: "hello world",
            replacementDictionary: ""
        )

        XCTAssertEqual(
            rendered,
            [
                "Static guidance.\n\n",
                """
                Working text:
                hello world

                Return only the final corrected text.
                """,
            ]
        )

        let withDictionary = templates.renderedUserPrompts(
            inputText: "hello world",
            replacementDictionary: "Replacement dictionary:\n- PostgreSQL: postgres"
        )
        XCTAssertEqual(
            withDictionary[1],
            """
            Replacement dictionary:
            - PostgreSQL: postgres

            Working text:
            hello world

            Return only the final corrected text.
            """
        )
    }

    /// The own-line-without-blank shape: the placeholder's line vanishes too,
    /// not just the placeholder text (review finding on the first cut, whose
    /// comment wrongly claimed the bare replacement covered this).
    func testEmptyDictionaryOnItsOwnLineWithoutBlankAlsoLeavesNoHole() {
        let templates = LLMPromptTemplates(
            systemContent: "ignored",
            userContent: "Guidance.\n{{replacement_dictionary}}\nWorking text:\n{{input_text}}"
        )
        let rendered = templates.renderedUserPrompts(
            inputText: "hello",
            replacementDictionary: ""
        )
        XCTAssertEqual(rendered.last, "Working text:\nhello")
    }

    /// The transcript is DICTATED CONTENT: a user talking about this app can
    /// legitimately say the placeholder literal, and substitution must never
    /// re-scan inserted transcript text (dictionary renders before input).
    func testDictatedPlaceholderLiteralSurvivesRendering() {
        let templates = LLMPromptTemplates(
            systemContent: "ignored",
            userContent: "{{replacement_dictionary}}\n\nWorking text:\n{{input_text}}"
        )
        let empty = templates.renderedUserPrompts(
            inputText: "the slot is {{replacement_dictionary}} in the template",
            replacementDictionary: ""
        )
        XCTAssertEqual(
            empty.last,
            "Working text:\nthe slot is {{replacement_dictionary}} in the template"
        )
        let full = templates.renderedUserPrompts(
            inputText: "the slot is {{replacement_dictionary}} in the template",
            replacementDictionary: "Replacement dictionary:\n- a: b"
        )
        XCTAssertEqual(
            full.last,
            "Replacement dictionary:\n- a: b\n\nWorking text:\nthe slot is {{replacement_dictionary}} in the template"
        )
    }

    func testRenderedUserPromptsUsesSingleMessageWhenTemplateStartsWithPlaceholder() {
        let templates = LLMPromptTemplates(
            systemContent: "ignored",
            userContent: "{{input_text}}"
        )

        let rendered = templates.renderedUserPrompts(
            inputText: "PostgreSQL rocks",
            replacementDictionary: ""
        )

        XCTAssertEqual(rendered, ["PostgreSQL rocks"])
    }

    func testUserPromptValidationAllowsReplacementDictionaryPlaceholderToBeMissing() throws {
        let templates = LLMPromptTemplates(
            systemContent: "ignored",
            userContent: "Transcript:\n{{input_text}}"
        )

        XCTAssertNoThrow(try templates.validateUserTemplate(fileName: "llm_user_prompt.toml"))
    }

    private func makeStore(replacementDictionary: String) throws -> AppConfigStore {
        let directory = makeTemporaryConfigDirectory()
        try write(replacementDictionary, named: "replacement_dictionary.toml", in: directory)
        return AppConfigStore(configDirectoryOverride: directory)
    }

    private func makeTemporaryConfigDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localvoxtral-config-tests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func write(_ content: String, named fileName: String, in directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try content.write(
            to: directory.appendingPathComponent(fileName, isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }
}
