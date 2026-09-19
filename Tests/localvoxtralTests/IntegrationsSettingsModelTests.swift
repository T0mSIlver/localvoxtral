import Foundation
import Synchronization
import XCTest

@testable import localvoxtral

/// Status derivation for every Integrations row: the plugin's installed /
/// not / update-available states, the foreign-statusline rule, opencode's
/// listed-vs-copied split, and herdr-row visibility.
final class IntegrationsSettingsModelTests: XCTestCase {
    // MARK: - Harness

    func testSetupSheetsRenderConsentButNoGeneratedCode() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/localvoxtral/SettingsView.swift"),
            encoding: .utf8
        )
        for forbidden in [
            "confirmation.preview",
            "plan.remoteCommands",
            "plan.updateCommands",
            "plan.sshConfigSnippet",
            "herdrPanelConfigSnippet",
            "claude.shellSetupSheet.preview",
            "integrations.statuslineSheet.preview",
            "Run on SSH host",
        ] {
            XCTAssertFalse(source.contains(forbidden), "Settings must not render \(forbidden)")
        }
        XCTAssertTrue(source.contains("Link(\"Details\""))
        XCTAssertTrue(source.contains("integrations.remote.setup.step."))
        XCTAssertTrue(source.contains("integrations.remote.setup.run"))
        XCTAssertTrue(source.contains("claude.remote.shellSetup.setUp"))
        XCTAssertTrue(source.contains("claude.shellSetupSheet.apply"))
        XCTAssertTrue(source.contains("integrations.statuslineSheet.apply"))
        XCTAssertEqual(
            OpencodePluginInstallService.consentSentence,
            "localvoxtral will edit ~/.config/opencode/plugins/localvoxtral.js and "
                + "~/.config/opencode/tui.json on this Mac."
        )
        XCTAssertFalse(OpencodePluginInstallService.consentSentence.contains("mkdir"))
    }

    @MainActor
    private func makeModel(
        fetchPluginListOutput: @escaping @Sendable () async -> String? = { nil },
        bundledPluginVersion: String? = nil,
        pluginService: any ClaudePluginInstalling = StubListPluginService(),
        statusline: ClaudeStatuslineInstallService? = nil,
        statuslineHookCommand: (@Sendable () -> String?)? = nil,
        opencode: OpencodePluginInstallService? = nil,
        herdrBinaryAvailable: @escaping @Sendable () -> Bool = { false },
        herdrPresenceReport: @escaping @Sendable () -> Bool = { false }
    ) -> ClaudeIntegrationSettingsModel {
        ClaudeIntegrationSettingsModel(
            registry: nil,
            listener: nil,
            pluginService: { pluginService },
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
            herdrBinaryAvailable: herdrBinaryAvailable,
            herdrPresenceReport: herdrPresenceReport
        )
    }

    // MARK: - Plugin status

    @MainActor
    func testInstalledPluginReportsItsVersion() async {
        let model = makeModel(
            fetchPluginListOutput: {
                "[{\"id\":\"some-other@market\",\"version\":\"2.0.0\",\"scope\":\"user\",\"enabled\":true},{\"id\":\"localvoxtral@localvoxtral\",\"version\":\"1.4.0\",\"scope\":\"user\",\"enabled\":true}]"
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
            fetchPluginListOutput: { "[{\"id\":\"localvoxtral@localvoxtral\",\"version\":\"1.3.0\",\"scope\":\"user\",\"enabled\":true}]" },
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
            fetchPluginListOutput: { "[{\"id\":\"localvoxtral@localvoxtral\",\"version\":\"1.5.0\",\"scope\":\"user\",\"enabled\":true}]" },
            bundledPluginVersion: "1.4.0"
        )
        await model.refreshIntegrationsStatuses()
        XCTAssertEqual(model.localPluginStatus, .installed(version: "1.5.0"))
        XCTAssertEqual(model.localPluginSentence, "Installed 1.5.0.")
    }

    @MainActor
    func testAbsentPluginReportsNotInstalled() async {
        let model = makeModel(
            fetchPluginListOutput: { "[{\"id\":\"some-other@market\",\"version\":\"2.0.0\",\"scope\":\"user\",\"enabled\":true}]" },
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
            fetchPluginListOutput: { "[{\"id\":\"localvoxtral@localvoxtral\",\"version\":\"unknown\",\"scope\":\"user\",\"enabled\":true}]" },
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
            fetchPluginListOutput: { "[{\"id\":\"claude-tools@other\",\"version\":\"2.1.220\",\"scope\":\"user\",\"enabled\":true},{\"id\":\"localvoxtral@localvoxtral\",\"version\":\"unknown\",\"scope\":\"user\",\"enabled\":true}]" },
            bundledPluginVersion: "2.1.220"
        )
        await model.refreshIntegrationsStatuses()
        XCTAssertEqual(model.localPluginStatus, .installed(version: nil))
    }

    func testPluginRowButtonsFollowTheStatus() {
        // A current plugin gets no install button, since pressing it would
        // reinstall the same files, and a missing one gets no Remove.
        let cases: [(ClaudePluginStatus, ClaudePluginStatus.PrimaryAction?, Bool)] = [
            (.notInstalled, .install, false),
            (.updateAvailable(installed: "1.0.0", bundled: "1.1.0"), .update, true),
            (.installed(version: "1.0.0"), nil, true),
            (.installed(version: nil), .installOrUpdate, true),
            (.unknown, .installOrUpdate, true),
        ]
        for (status, action, remove) in cases {
            XCTAssertEqual(status.primaryAction, action, "\(status)")
            XCTAssertEqual(status.offersRemove, remove, "\(status)")
        }
        XCTAssertEqual(ClaudePluginStatus.PrimaryAction.install.title, "Install")
        XCTAssertEqual(ClaudePluginStatus.PrimaryAction.update.title, "Update")
    }

    @MainActor
    func testLaunchUpdatesAnOutdatedPluginAndNothingElse() async {
        let listing = Mutex("1.0.0")
        let service = RecordingPluginService { listing.withLock { $0 = "1.1.0" } }
        let model = makeModel(
            fetchPluginListOutput: {
                let version = listing.withLock { $0 }
                return "[{\"id\":\"localvoxtral@localvoxtral\",\"version\":\"\(version)\",\"scope\":\"user\",\"enabled\":true}]"
            },
            bundledPluginVersion: "1.1.0",
            pluginService: service
        )
        await model.updateOutdatedPluginAtLaunch()
        XCTAssertEqual(service.calls.withLock { $0 }, ["update"])
        XCTAssertEqual(model.localPluginStatus, .installed(version: "1.1.0"))

        // Current now: a second launch touches nothing.
        await model.updateOutdatedPluginAtLaunch()
        XCTAssertEqual(service.calls.withLock { $0 }, ["update"])
    }

    @MainActor
    func testLaunchNeverInstallsAMissingPlugin() async {
        for listing in [String?.none, "[]"] {
            let service = RecordingPluginService()
            let model = makeModel(
                fetchPluginListOutput: { listing },
                bundledPluginVersion: "1.1.0",
                pluginService: service
            )
            await model.updateOutdatedPluginAtLaunch()
            XCTAssertEqual(service.calls.withLock { $0 }, [], "\(String(describing: listing))")
        }
    }

    @MainActor
    func testFailedLaunchUpdateRaisesNoAlertAndKeepsTheButton() async {
        let service = RecordingPluginService(fails: true)
        let model = makeModel(
            fetchPluginListOutput: { "[{\"id\":\"localvoxtral@localvoxtral\",\"version\":\"1.0.0\",\"scope\":\"user\",\"enabled\":true}]" },
            bundledPluginVersion: "1.1.0",
            pluginService: service
        )
        await model.updateOutdatedPluginAtLaunch()
        XCTAssertEqual(service.calls.withLock { $0 }, ["update"])
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.localPluginStatus.primaryAction, .update)
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
            // Another copy of the app that still runs: not this install.
            (ClaudeStatuslineState(
                fileExists: true,
                data: Data("{\"statusLine\":{\"type\":\"command\",\"command\":\"\(hook.replacingOccurrences(of: "/Applications/", with: "/tmp/try-pr/"))\"}}".utf8)
            ), .otherCopy),
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
            model.statuslineResult, "Edited in settings.json; remove it there."
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
        // Clear the install phase's writes: what follows pins the remove.
        fs.writtenPlugin = nil
        fs.writtenTUI = nil
        await model.removeOpencodePlugin()
        XCTAssertEqual(model.opencodeResult, "Removed.")
        XCTAssertTrue(fs.deletedPlugin)
        XCTAssertTrue(
            fs.deletedTUI,
            "a tui.json holding only our entry is deleted, not emptied"
        )
        XCTAssertNil(fs.writtenTUI)
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
    func testHerdrRowReservedAtConstructionWhenBinaryPresent() {
        // m8: the binary check seeds visibility synchronously — no refresh,
        // no await — so the row paints on first paint instead of popping in.
        let model = makeModel(herdrBinaryAvailable: { true })
        XCTAssertTrue(
            model.isHerdrDetected,
            "binary on PATH reserves the row at construction"
        )
    }

    @MainActor
    func testHerdrRowAppearsWhenHerdrReports() async {
        let model = makeModel(herdrPresenceReport: { true })
        await model.refreshIntegrationsStatuses()
        XCTAssertTrue(model.isHerdrDetected)
        XCTAssertEqual(
            ClaudeIntegrationSettingsModel.herdrDetectedSentence,
            "Found; panes join automatically."
        )
    }

    // MARK: - Probe ordering

    @MainActor
    func testHerdrCandidatesProbePathBeforeTheKnownInstallDirectories() {
        let candidates = ClaudeHerdrAvailability.herdrCandidates(environment: [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/someone",
        ])
        XCTAssertEqual(candidates, [
            "/usr/bin/herdr", "/bin/herdr",
            "/Users/someone/.local/bin/herdr",
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            "/Users/someone/.nix-profile/bin/herdr",
            "/nix/var/nix/profiles/default/bin/herdr",
            "/run/current-system/sw/bin/herdr",
        ])
    }

    /// Field finding 2026-09-15: the owner's Mac has herdr from Homebrew at
    /// `/opt/homebrew/bin`, which a GUI app's PATH (`/usr/bin:/bin:/usr/sbin:
    /// /sbin`) never contains, so the Integrations pane said "Not found." The
    /// fixed directories are the ones herdr itself probes on a remote Mac
    /// (`src/remote/attach.rs`, 0.9.0): Homebrew, /usr/local, Nix.
    @MainActor
    func testHerdrProbeFindsAHomebrewHerdrOutsideTheGUIPATH() {
        let guiEnvironment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/someone"]
        XCTAssertTrue(ClaudeHerdrAvailability.isHerdrBinaryAvailable(
            environment: guiEnvironment,
            isExecutable: { $0 == "/opt/homebrew/bin/herdr" }
        ))
        XCTAssertTrue(ClaudeHerdrAvailability.isHerdrBinaryAvailable(
            environment: guiEnvironment,
            isExecutable: { $0 == "/usr/local/bin/herdr" }
        ))
    }

    /// A directory already on PATH is probed once, in its PATH position.
    @MainActor
    func testHerdrCandidatesDoNotRepeatADirectoryAlreadyOnPATH() {
        let candidates = ClaudeHerdrAvailability.herdrCandidates(environment: [
            "PATH": "/opt/homebrew/bin:/usr/bin",
            "HOME": "/Users/someone",
        ])
        XCTAssertEqual(candidates.filter { $0 == "/opt/homebrew/bin/herdr" }.count, 1)
        XCTAssertEqual(candidates.first, "/opt/homebrew/bin/herdr")
    }

    /// No HOME: the home-relative entries are skipped, the fixed ones stay.
    @MainActor
    func testHerdrCandidatesWithoutHOMEKeepTheFixedDirectories() {
        let candidates = ClaudeHerdrAvailability.herdrCandidates(environment: ["PATH": "/usr/bin"])
        XCTAssertEqual(candidates, [
            "/usr/bin/herdr",
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            "/nix/var/nix/profiles/default/bin/herdr",
            "/run/current-system/sw/bin/herdr",
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
/// `["plugin", "list", "--json"]` — the pane's entire plugin status rests on that argv,
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
        XCTAssertEqual(catcher.invocations.map(\.arguments), [["plugin", "list", "--json"]])
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
        XCTAssertEqual(catcher.invocations.map(\.arguments), [["plugin", "list", "--json"]])
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
private final class RecordingPluginService: ClaudePluginInstalling, Sendable {
    struct Failure: Error {}
    let calls = Mutex<[String]>([])
    private let fails: Bool
    private let onUpdate: @Sendable () -> Void

    init(fails: Bool = false, onUpdate: @escaping @Sendable () -> Void = {}) {
        self.fails = fails
        self.onUpdate = onUpdate
    }

    func installPlugin() throws { calls.withLock { $0.append("install") } }
    func updatePlugin() throws { calls.withLock { $0.append("reinstall") } }
    func updateInstalledPlugin() throws {
        calls.withLock { $0.append("update") }
        if fails { throw Failure() }
        onUpdate()
    }
    func uninstallPlugin() throws { calls.withLock { $0.append("uninstall") } }
}

private final class StubListPluginService: ClaudePluginInstalling, @unchecked Sendable {
    func installPlugin() throws {}
    func updatePlugin() throws {}
    func updateInstalledPlugin() throws {}
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
    /// m9: the double used to swallow TUI deletion, so the model test could
    /// not pin that Remove drops the tui.json-only file.
    var deletedTUI = false

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
    func deleteTUI() throws { deletedTUI = true }
}
