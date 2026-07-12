import Foundation
import XCTest

@testable import localvoxtral

/// `AppConfigStore.reconcileBundledDefaults()`: existing installs must pick up
/// improved bundled config defaults — silently when the seeded file was never
/// edited, and only with the user's consent (`adoptBundledDefaults` /
/// `recordKeptCustomizedDefaults`) when it was.
final class AppConfigDefaultsReconcileTests: XCTestCase {
    private static let allConfigFileNames = [
        "replacement_dictionary.toml",
        "llm_system_prompt.toml",
        "llm_user_prompt.toml",
        "llm_system_prompt_agent.toml",
        "llm_user_prompt_agent.toml",
        "terminal_apps.toml",
    ]

    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    /// Guard rail for `BundledConfigDefaultHistory`: every bundled default in
    /// this build must be registered, or existing installs would treat the
    /// unedited previous seed as a customization and nag instead of silently
    /// refreshing. If this fails, append the printed hash for that file to
    /// `BundledConfigDefaultHistory.knownDefaultHashes` (keep the old ones).
    func testCurrentBundledDefaultsAreRegisteredInHistory() throws {
        for fileName in Self.allConfigFileNames {
            let data = try bundledData(for: fileName)
            let hash = AppConfigStore.sha256Hex(data)
            XCTAssertTrue(
                BundledConfigDefaultHistory.knownDefaultHashes[fileName, default: []]
                    .contains(hash),
                "You changed the bundled \(fileName) — add \"\(hash)\" to BundledConfigDefaultHistory.knownDefaultHashes so existing installs pick it up."
            )
        }
    }

    func testReconcileRefreshesUneditedStaleSeed() throws {
        let directory = makeTemporaryConfigDirectory()
        let staleSeed = "content = \"an older shipped default\""
        try write(staleSeed, named: "llm_system_prompt.toml", in: directory)

        var hashes = BundledConfigDefaultHistory.knownDefaultHashes
        hashes["llm_system_prompt.toml", default: []]
            .insert(AppConfigStore.sha256Hex(Data(staleSeed.utf8)))
        let store = AppConfigStore(
            configDirectoryOverride: directory,
            knownDefaultHashes: hashes
        )

        let outcome = store.reconcileBundledDefaults()

        XCTAssertEqual(outcome.refreshedFileNames, ["llm_system_prompt.toml"])
        XCTAssertEqual(outcome.customizedOutdatedFileNames, [])
        let refreshed = try Data(
            contentsOf: directory.appendingPathComponent("llm_system_prompt.toml"))
        XCTAssertEqual(refreshed, try bundledData(for: "llm_system_prompt.toml"))
    }

    func testReconcileReportsCustomizedFileWithoutTouchingIt() throws {
        let directory = makeTemporaryConfigDirectory()
        let customized = "content = \"my own carefully tuned prompt\""
        try write(customized, named: "llm_system_prompt.toml", in: directory)
        let store = AppConfigStore(configDirectoryOverride: directory)

        let outcome = store.reconcileBundledDefaults()

        XCTAssertEqual(outcome.refreshedFileNames, [])
        XCTAssertEqual(outcome.customizedOutdatedFileNames, ["llm_system_prompt.toml"])
        let untouched = try String(
            contentsOf: directory.appendingPathComponent("llm_system_prompt.toml"),
            encoding: .utf8
        )
        XCTAssertEqual(untouched, customized)
    }

    func testReconcileFreshSeedReportsNothing() throws {
        let store = AppConfigStore(configDirectoryOverride: makeTemporaryConfigDirectory())
        _ = store.configDirectoryURL()

        let outcome = store.reconcileBundledDefaults()

        XCTAssertEqual(outcome, BundledDefaultsReconciliation())
    }

    func testAdoptBundledDefaultsBacksUpAndReplaces() throws {
        let directory = makeTemporaryConfigDirectory()
        let customized = "content = \"my own carefully tuned prompt\""
        try write(customized, named: "llm_system_prompt.toml", in: directory)
        let store = AppConfigStore(
            configDirectoryOverride: directory,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let backups = store.adoptBundledDefaults(fileNames: ["llm_system_prompt.toml"])

        XCTAssertEqual(backups.count, 1)
        let backupName = try XCTUnwrap(backups.first)
        XCTAssertTrue(backupName.hasPrefix("llm_system_prompt.toml.backup-"))
        let backupContent = try String(
            contentsOf: directory.appendingPathComponent(backupName),
            encoding: .utf8
        )
        XCTAssertEqual(backupContent, customized)
        let adopted = try Data(
            contentsOf: directory.appendingPathComponent("llm_system_prompt.toml"))
        XCTAssertEqual(adopted, try bundledData(for: "llm_system_prompt.toml"))

        // Now in sync — no further prompt.
        XCTAssertEqual(store.reconcileBundledDefaults(), BundledDefaultsReconciliation())
    }

    func testAdoptOnlyTouchesRequestedFiles() throws {
        let directory = makeTemporaryConfigDirectory()
        let customizedSystem = "content = \"my system prompt\""
        let customizedUser = "content = \"mine: {{input_text}}\""
        try write(customizedSystem, named: "llm_system_prompt.toml", in: directory)
        try write(customizedUser, named: "llm_user_prompt.toml", in: directory)
        let store = AppConfigStore(configDirectoryOverride: directory)

        _ = store.adoptBundledDefaults(fileNames: ["llm_system_prompt.toml"])

        let untouched = try String(
            contentsOf: directory.appendingPathComponent("llm_user_prompt.toml"),
            encoding: .utf8
        )
        XCTAssertEqual(untouched, customizedUser)
        XCTAssertEqual(
            store.reconcileBundledDefaults().customizedOutdatedFileNames,
            ["llm_user_prompt.toml"]
        )
    }

    func testKeepMineSuppressesRepromptForSameDefault() throws {
        let directory = makeTemporaryConfigDirectory()
        let customized = "content = \"my own carefully tuned prompt\""
        try write(customized, named: "llm_system_prompt.toml", in: directory)
        let store = AppConfigStore(configDirectoryOverride: directory)

        XCTAssertEqual(
            store.reconcileBundledDefaults().customizedOutdatedFileNames,
            ["llm_system_prompt.toml"]
        )

        store.recordKeptCustomizedDefaults(fileNames: ["llm_system_prompt.toml"])

        let afterDecision = store.reconcileBundledDefaults()
        XCTAssertEqual(afterDecision.customizedOutdatedFileNames, [])
        XCTAssertEqual(afterDecision.refreshedFileNames, [])
        let untouched = try String(
            contentsOf: directory.appendingPathComponent("llm_system_prompt.toml"),
            encoding: .utf8
        )
        XCTAssertEqual(untouched, customized)
    }

    /// A recorded "keep mine" is tied to the bundled hash it declined: when the
    /// bundled default changes again, the prompt must come back.
    func testKeepMineRepromptsWhenDefaultChangesAgain() throws {
        let directory = makeTemporaryConfigDirectory()
        let customized = "content = \"my own carefully tuned prompt\""
        try write(customized, named: "llm_system_prompt.toml", in: directory)
        let store = AppConfigStore(configDirectoryOverride: directory)
        store.recordKeptCustomizedDefaults(fileNames: ["llm_system_prompt.toml"])

        // Simulate the NEXT release shipping a different default by rewriting
        // the recorded decision to point at a hash that no longer matches the
        // bundled file.
        let stateURL = directory.appendingPathComponent(".bundled-defaults-state.json")
        let staleState = #"{"resolvedBundledHashes":{"llm_system_prompt.toml":"0000"}}"#
        try staleState.write(to: stateURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            store.reconcileBundledDefaults().customizedOutdatedFileNames,
            ["llm_system_prompt.toml"]
        )
    }

    private func bundledData(for fileName: String) throws -> Data {
        let resourceName = fileName.replacingOccurrences(of: ".toml", with: "")
        let url = try XCTUnwrap(
            Bundle.localvoxtralResources.url(forResource: resourceName, withExtension: "toml"),
            "Missing bundled resource \(fileName)"
        )
        return try Data(contentsOf: url)
    }

    private func makeTemporaryConfigDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "localvoxtral-defaults-reconcile-tests-\(UUID().uuidString)", isDirectory: true)
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
