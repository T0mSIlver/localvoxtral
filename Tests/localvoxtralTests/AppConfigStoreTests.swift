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

        let templates = store.loadLLMPromptTemplates()
        XCTAssertFalse(templates.systemContent.trimmed.isEmpty)
        XCTAssertFalse(templates.userContent.trimmed.isEmpty)
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

    func testRenderedUserPromptReplacesKnownPlaceholdersAndLeavesUnknownOnes() {
        let templates = LLMPromptTemplates(
            systemContent: "ignored",
            userContent: "Input: {{input_text}}\nOriginal: {{original_text}}\nRules: {{replacement_dictionary}}\nUnknown: {{unknown}}"
        )

        let rendered = templates.renderedUserPrompt(
            inputText: "working",
            originalText: "raw",
            replacementDictionary: "- PostgreSQL: postgres"
        )

        XCTAssertEqual(
            rendered,
            """
            Input: working
            Original: raw
            Rules: - PostgreSQL: postgres
            Unknown: {{unknown}}
            """
        )
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
