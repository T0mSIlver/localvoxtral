import Foundation
import XCTest

@testable import localvoxtral

/// Status derivation for every Integrations row: the plugin's installed /
/// not / update-available states, the foreign-statusline rule, opencode's
/// listed-vs-copied split, and herdr-row visibility.
final class IntegrationsSettingsModelTests: XCTestCase {
    // MARK: - Harness

    @MainActor
    private func makeModel(
        fetchPluginListOutput: @escaping @Sendable () async -> String? = { nil },
        bundledPluginVersion: String? = nil,
        statusline: ClaudeStatuslineInstallService? = nil,
        statuslineHookCommand: (@Sendable () -> String?)? = nil,
        opencode: OpencodePluginInstallService? = nil,
        herdrPresenceReport: @escaping @Sendable () -> Bool = { false }
    ) -> ClaudeIntegrationSettingsModel {
        ClaudeIntegrationSettingsModel(
            registry: nil,
            listener: nil,
            pluginService: { StubListPluginService() },
            // Synchronous: the production default hops to a detached task,
            // which would make every assertion below a race.
            performAsync: { body in
                do {
                    try body()
                    return nil
                } catch {
                    return ClaudePluginActionFailure(error)
                }
            },
            fetchPluginListOutput: fetchPluginListOutput,
            bundledPluginVersion: bundledPluginVersion,
            statuslineService: { statusline },
            statuslineHookCommand: statuslineHookCommand ?? { nil },
            opencodeService: { opencode },
            herdrPresenceReport: herdrPresenceReport
        )
    }

    // MARK: - Plugin status

    @MainActor
    func testInstalledPluginReportsItsVersion() async {
        let model = makeModel(
            fetchPluginListOutput: {
                "localvoxtral@localvoxtral 1.4.0\nsome-other@market 2.0.0"
            },
            bundledPluginVersion: "1.4.0"
        )
        await model.refreshIntegrationsStatuses()
        XCTAssertEqual(model.localPluginStatus, .installed(version: "1.4.0"))
        XCTAssertEqual(model.localPluginSentence, "Installed 1.4.0.")
    }

    @MainActor
    func testOlderInstalledPluginReportsUpdateAvailable() async {
        let model = makeModel(
            fetchPluginListOutput: { "localvoxtral@localvoxtral 1.3.0" },
            bundledPluginVersion: "1.4.0"
        )
        await model.refreshIntegrationsStatuses()
        XCTAssertEqual(
            model.localPluginStatus,
            .updateAvailable(installed: "1.3.0", bundled: "1.4.0")
        )
        XCTAssertEqual(model.localPluginSentence, "Update available.")
    }

    @MainActor
    func testNewerInstalledPluginIsNotAnUpdate() async {
        // m7: a manually installed 1.5.0 over a bundled 1.4.0 is newer, not
        // stale — offering to "update" it would install the OLDER marketplace.
        let model = makeModel(
            fetchPluginListOutput: { "localvoxtral@localvoxtral 1.5.0" },
            bundledPluginVersion: "1.4.0"
        )
        await model.refreshIntegrationsStatuses()
        XCTAssertEqual(model.localPluginStatus, .installed(version: "1.5.0"))
        XCTAssertEqual(model.localPluginSentence, "Installed 1.5.0.")
    }

    @MainActor
    func testAbsentPluginReportsNotInstalled() async {
        let model = makeModel(
            fetchPluginListOutput: { "some-other@market 2.0.0" },
            bundledPluginVersion: "1.4.0"
        )
        await model.refreshIntegrationsStatuses()
        XCTAssertEqual(model.localPluginStatus, .notInstalled)
        XCTAssertEqual(model.localPluginSentence, "Not installed.")
    }

    @MainActor
    func testFailedListingReportsUnknownRatherThanNotInstalled() async {
        // Absence of evidence is not evidence of absence: claiming "not
        // installed" would invite an install over a setup we failed to read.
        let model = makeModel(
            fetchPluginListOutput: { nil },
            bundledPluginVersion: "1.4.0"
        )
        await model.refreshIntegrationsStatuses()
        XCTAssertEqual(model.localPluginStatus, .unknown)
    }

    @MainActor
    func testInstalledWithoutAVersionIsStillInstalled() async {
        let model = makeModel(
            fetchPluginListOutput: { "localvoxtral@localvoxtral" },
            bundledPluginVersion: "1.4.0"
        )
        await model.refreshIntegrationsStatuses()
        XCTAssertEqual(model.localPluginStatus, .installed(version: nil))
        XCTAssertEqual(model.localPluginSentence, "Installed.")
    }

    @MainActor
    func testAnotherPluginsVersionIsNeverOurs() async {
        // Only the line carrying our reference may supply a version: a CLI
        // banner or another plugin's number must never read as ours.
        let model = makeModel(
            fetchPluginListOutput: { "claude 2.1.220\nlocalvoxtral@localvoxtral" },
            bundledPluginVersion: "2.1.220"
        )
        await model.refreshIntegrationsStatuses()
        XCTAssertEqual(model.localPluginStatus, .installed(version: nil))
    }

    // MARK: - Status line row

    @MainActor
    func testStatuslineRowStates() {
        let hook = "/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook --statusline"
        for (state, expected): (ClaudeStatuslineState, ClaudeStatuslineInstallService.Status) in [
            (ClaudeStatuslineState(fileExists: false), .notConfigured),
            (ClaudeStatuslineState(
                fileExists: true,
                data: Data("{\"statusLine\":{\"type\":\"command\",\"command\":\"\(hook)\"}}".utf8)
            ), .installed),
            (ClaudeStatuslineState(
                fileExists: true,
                data: Data("{\"statusLine\":{\"type\":\"command\",\"command\":\"mine\"}}".utf8)
            ), .foreign),
        ] {
            let model = makeModel(
                statusline: ClaudeStatuslineInstallService(
                    fileSystem: StubModelStatuslineFS(state: state),
                    isExecutableFile: { _ in true }
                ),
                statuslineHookCommand: { hook }
            )
            model.refreshStatuslineStatus()
            XCTAssertEqual(model.statuslineStatus, expected)
        }
        XCTAssertEqual(
            ClaudeStatuslineInstallService.sentence(for: .notConfigured), "Not installed."
        )
    }

    @MainActor
    func testStatuslineApplyAndRemoveRefreshTheRow() async {
        let fs = StubModelStatuslineFS(state: ClaudeStatuslineState(fileExists: false))
        let model = makeModel(
            statusline: ClaudeStatuslineInstallService(
                fileSystem: fs, isExecutableFile: { _ in true }
            ),
            statuslineHookCommand: {
                "/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook --statusline"
            }
        )
        model.refreshStatuslineStatus()
        XCTAssertEqual(model.statuslineSentence, "Not installed.")
        await model.applyStatuslineSetup()
        XCTAssertEqual(model.statuslineResult, "Installed.")
        XCTAssertNotNil(fs.written)
        fs.state = ClaudeStatuslineState(fileExists: true, data: fs.written?.data)
        await model.removeStatusline()
        XCTAssertEqual(model.statuslineResult, "Removed.")
        XCTAssertTrue(fs.deleted)
    }

    @MainActor
    func testStatuslineRemoveOnEditedEntryReportsEditedSentence() async {
        // M3: removing a user-edited formerly-ours entry refuses with the
        // one-sentence status instead of deleting.
        let hook = "/Applications/localvoxtral.app/Contents/MacOS/localvoxtral-claude-hook --statusline"
        let existing = try? JSONSerialization.data(withJSONObject: [
            "statusLine": ["type": "command", "command": "\(hook) --extra"],
        ])
        let fs = StubModelStatuslineFS(state: ClaudeStatuslineState(
            fileExists: true, data: existing
        ))
        let model = makeModel(
            statusline: ClaudeStatuslineInstallService(
                fileSystem: fs, isExecutableFile: { _ in true }
            ),
            statuslineHookCommand: { hook }
        )
        model.refreshStatuslineStatus()
        XCTAssertEqual(model.statuslineStatus, .edited)
        await model.removeStatusline()
        XCTAssertEqual(
            model.statuslineResult, "Edited by you; remove it in settings.json."
        )
        XCTAssertFalse(fs.deleted, "an edited entry is never deleted")
    }

    // MARK: - opencode row

    @MainActor
    func testOpencodeRowStates() {
        let listed = try? JSONSerialization.data(withJSONObject: [
            "plugin": [OpencodePluginInstallService.tuiPluginEntry],
        ])
        for (state, expected): (OpencodePluginState, OpencodePluginInstallService.Status) in [
            (OpencodePluginState(), .notInstalled),
            (OpencodePluginState(
                pluginFileExists: true, pluginData: Data("js".utf8), tuiFileExists: false
            ), .installedUnlisted),
            (OpencodePluginState(
                pluginFileExists: true, pluginData: Data("js".utf8),
                tuiFileExists: true, tuiData: listed
            ), .installed),
        ] {
            let model = makeModel(
                opencode: OpencodePluginInstallService(
                    bundledPluginData: { Data("js".utf8) },
                    fileSystem: StubModelOpencodeFS(state: state)
                )
            )
            model.refreshOpencodeStatus()
            XCTAssertEqual(model.opencodeStatus, expected)
        }
    }

    @MainActor
    func testOpencodeInstallAndRemoveRefreshTheRow() async {
        let fs = StubModelOpencodeFS(state: OpencodePluginState())
        let model = makeModel(
            opencode: OpencodePluginInstallService(
                bundledPluginData: { Data("js".utf8) }, fileSystem: fs
            )
        )
        await model.installOpencodePlugin()
        XCTAssertEqual(model.opencodeResult, "Installed.")
        XCTAssertNotNil(fs.writtenPlugin)
        XCTAssertNotNil(fs.writtenTUI)
        fs.state = OpencodePluginState(
            pluginFileExists: true, pluginData: Data("js".utf8),
            tuiFileExists: true, tuiData: fs.writtenTUI?.data
        )
        await model.removeOpencodePlugin()
        XCTAssertEqual(model.opencodeResult, "Removed.")
        XCTAssertTrue(fs.deletedPlugin)
    }

    // MARK: - herdr row

    @MainActor
    func testHerdrRowIsAbsentWhenNothingReportsHerdr() async {
        let model = makeModel(herdrPresenceReport: { false })
        await model.refreshIntegrationsStatuses()
        XCTAssertFalse(
            model.isHerdrDetected,
            "the view hides the row on this flag: a row that can only say 'not found' is noise"
        )
    }

    @MainActor
    func testHerdrRowAppearsWhenHerdrReports() async {
        let model = makeModel(herdrPresenceReport: { true })
        await model.refreshIntegrationsStatuses()
        XCTAssertTrue(model.isHerdrDetected)
        XCTAssertEqual(
            ClaudeIntegrationSettingsModel.herdrDetectedSentence,
            "Found — panes join automatically."
        )
    }

    // MARK: - Probe ordering

    @MainActor
    func testHerdrCandidatesProbePathBeforeHomeLocalBin() {
        let candidates = ClaudeHerdrAvailability.herdrCandidates(environment: [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/someone",
        ])
        XCTAssertEqual(candidates, [
            "/usr/bin/herdr", "/bin/herdr", "/Users/someone/.local/bin/herdr",
        ])
    }

    @MainActor
    func testHerdrProbeIsPinnedWithoutTheMachinesOwnPATH() {
        XCTAssertTrue(ClaudeHerdrAvailability.isHerdrBinaryAvailable(
            environment: ["PATH": "/usr/bin", "HOME": "/Users/someone"],
            isExecutable: { $0 == "/Users/someone/.local/bin/herdr" }
        ))
        XCTAssertFalse(ClaudeHerdrAvailability.isHerdrBinaryAvailable(
            environment: ["PATH": "/usr/bin", "HOME": "/Users/someone"],
            isExecutable: { _ in false }
        ))
    }
}

/// The `claude plugin list` probe on the real service: a failed listing is
/// nil (unknown), never a throw — only the runner's own failures throw.
///
/// M4: every test captures the invocation the seam received and pins it to
/// `["plugin", "list"]` — the pane's entire plugin status rests on that argv,
/// and a stub discarding its input would let a wrong subcommand pass.
final class ClaudePluginListProbeTests: XCTestCase {
    func testSuccessfulListingReturnsStdout() throws {
        let catcher = ProbeInvocationCatcher()
        let service = ClaudePluginInstallService(
            claudeExecutableURL: URL(fileURLWithPath: "/usr/bin/claude"),
            marketplaceURL: URL(fileURLWithPath: "/marketplace"),
            runner: {
                catcher.invocations.append($0)
                return ClaudePluginInstallService.RunResult(exitCode: 0, message: "out")
            }
        )
        XCTAssertEqual(try service.pluginListOutput(), "out")
        XCTAssertEqual(catcher.invocations.map(\.arguments), [["plugin", "list"]])
    }

    func testFailedListingIsNil() throws {
        let catcher = ProbeInvocationCatcher()
        let service = ClaudePluginInstallService(
            claudeExecutableURL: URL(fileURLWithPath: "/usr/bin/claude"),
            marketplaceURL: URL(fileURLWithPath: "/marketplace"),
            runner: {
                catcher.invocations.append($0)
                return ClaudePluginInstallService.RunResult(exitCode: 1, message: "nope")
            }
        )
        XCTAssertNil(try service.pluginListOutput())
        XCTAssertEqual(catcher.invocations.map(\.arguments), [["plugin", "list"]])
    }

    func testMissingCLIIsNil() throws {
        let catcher = ProbeInvocationCatcher()
        let service = ClaudePluginInstallService(
            claudeExecutableURL: nil,
            marketplaceURL: URL(fileURLWithPath: "/marketplace"),
            runner: {
                catcher.invocations.append($0)
                return ClaudePluginInstallService.RunResult(exitCode: 0, message: "out")
            }
        )
        XCTAssertNil(try service.pluginListOutput())
        XCTAssertTrue(catcher.invocations.isEmpty, "no CLI means no invocation")
    }
}

/// Sendable box so the probe tests can record the invocation a `@Sendable`
/// runner received without tripping Swift 6 capture rules.
private final class ProbeInvocationCatcher: @unchecked Sendable {
    var invocations: [ClaudePluginInstallService.Invocation] = []
}

// MARK: - Doubles

/// `ClaudePluginInstalling` stub that also answers the list probe.
private final class StubListPluginService: ClaudePluginInstalling, @unchecked Sendable {
    func installPlugin() throws {}
    func updatePlugin() throws {}
    func uninstallPlugin() throws {}
    func pluginListOutput() throws -> String? { nil }
}

private final class StubModelStatuslineFS: ClaudeStatuslineFileSystem, @unchecked Sendable {
    var state: ClaudeStatuslineState
    var written: (data: Data, permissions: UInt16)?
    var deleted = false

    init(state: ClaudeStatuslineState) { self.state = state }

    func readState() throws -> ClaudeStatuslineState { state }
    func createDirectory(permissions: UInt16) throws {}
    func atomicWrite(_ data: Data, permissions: UInt16) throws {
        written = (data, permissions)
    }
    func deleteFile() throws { deleted = true }
}

private final class StubModelOpencodeFS: OpencodePluginFileSystem, @unchecked Sendable {
    var state: OpencodePluginState
    var writtenPlugin: (data: Data, permissions: UInt16)?
    var writtenTUI: (data: Data, permissions: UInt16)?
    var deletedPlugin = false

    init(state: OpencodePluginState) { self.state = state }

    func readState() throws -> OpencodePluginState { state }
    func createPluginsDirectory(permissions: UInt16) throws {}
    func createConfigDirectory(permissions: UInt16) throws {}
    func atomicWritePlugin(_ data: Data, permissions: UInt16) throws {
        writtenPlugin = (data, permissions)
    }
    func atomicWriteTUI(_ data: Data, permissions: UInt16) throws {
        writtenTUI = (data, permissions)
    }
    func deletePlugin() throws { deletedPlugin = true }
    func deleteTUI() throws {}
}
