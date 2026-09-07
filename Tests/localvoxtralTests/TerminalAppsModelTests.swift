import XCTest

@testable import localvoxtral

/// The Terminals section's derivations (owner decision, 2026-09-07): the
/// status-dot matrix per terminal, the capability verdicts the pane renders,
/// the user-added list's guards, and the one-shot `terminal_apps.toml`
/// migration. All LaunchServices and Info.plist reads are injected — the real
/// ones are never exercised from tests.
@MainActor
final class TerminalAppsModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName = ""

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuiteName = "localvoxtral.TerminalAppsModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        self.defaults = defaults
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = ""
        try await super.tearDown()
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults, environment: [:])
    }

    /// A model whose LaunchServices seam answers from a fixture table:
    /// bundle id → installed version. The URL handed to the version reader
    /// is built from the bundle id, so fixtures key both seams on it.
    private func makeModel(
        store: SettingsStore,
        installedVersions: [String: String] = [:],
        isCmuxSocketSetUp: @escaping @Sendable () -> Bool = { false }
    ) -> TerminalAppsSettingsModel {
        TerminalAppsSettingsModel(
            settings: store,
            applicationURLForBundleID: { bundleID in
                installedVersions[bundleID] != nil
                    ? URL(fileURLWithPath: "/Applications/\(bundleID).app")
                    : nil
            },
            bundleShortVersion: { url in
                installedVersions[url.deletingPathExtension().lastPathComponent]
            },
            isCmuxSocketSetUp: isCmuxSocketSetUp
        )
    }

    // MARK: - Dot matrix

    func testNotInstalledTerminalsAreGrey() {
        for app in TerminalAppCatalog.builtIn {
            XCTAssertEqual(
                TerminalAppsSettingsModel.dot(
                    for: TerminalAppsSettingsModel.Row(app: app, installed: false, version: nil),
                    isCmuxSocketSetUp: false
                ),
                .grey,
                "\(app.slug): not installed must be grey whatever its capabilities"
            )
        }
    }

    func testJoinCapableTerminalsAreGreenWhenInstalled() {
        // iTerm2 and Terminal.app: installed is all they need.
        for slug in ["iterm2", "apple-terminal"] {
            let app = XCTUnwrapApp(slug)
            XCTAssertEqual(
                TerminalAppsSettingsModel.dot(
                    for: TerminalAppsSettingsModel.Row(app: app, installed: true, version: nil),
                    isCmuxSocketSetUp: false
                ),
                .green,
                "\(slug): installed with no further gate is green"
            )
        }
    }

    func testGhosttyDotFollowsTheVersionFloor() {
        let ghostty = XCTUnwrapApp("ghostty")
        func dot(_ version: String?) -> SettingsStatusDot {
            TerminalAppsSettingsModel.dot(
                for: TerminalAppsSettingsModel.Row(app: ghostty, installed: true, version: version),
                isCmuxSocketSetUp: false
            )
        }
        // Below the floor or unreadable: yellow — never green on a version we
        // could not parse.
        XCTAssertEqual(dot(nil), .yellow)
        XCTAssertEqual(dot("1.3.2"), .yellow)
        XCTAssertEqual(dot("not-a-version"), .yellow)
        // At or above 1.4: green.
        XCTAssertEqual(dot("1.4"), .green)
        XCTAssertEqual(dot("1.4.0"), .green)
        XCTAssertEqual(dot("1.5"), .green)
        XCTAssertEqual(dot("2.0"), .green)
        // A major bump clears the floor regardless of minor.
        XCTAssertEqual(dot("2"), .green)
    }

    func testGhosttyFloorComparisonCases() {
        XCTAssertTrue(TerminalAppCatalog.meetsGhosttyFloor("1.4"))
        XCTAssertTrue(TerminalAppCatalog.meetsGhosttyFloor("1.4.0"))
        XCTAssertTrue(TerminalAppCatalog.meetsGhosttyFloor("1.10"))
        XCTAssertFalse(TerminalAppCatalog.meetsGhosttyFloor("1.3.9"))
        XCTAssertFalse(TerminalAppCatalog.meetsGhosttyFloor("0.9"))
        XCTAssertFalse(TerminalAppCatalog.meetsGhosttyFloor(nil))
        XCTAssertFalse(TerminalAppCatalog.meetsGhosttyFloor(""))
        XCTAssertFalse(TerminalAppCatalog.meetsGhosttyFloor("beta"))
    }

    func testCmuxDotFollowsSocketSetup() {
        let cmux = XCTUnwrapApp("cmux")
        for (setUp, expected) in [(true, SettingsStatusDot.green), (false, SettingsStatusDot.yellow)] {
            XCTAssertEqual(
                TerminalAppsSettingsModel.dot(
                    for: TerminalAppsSettingsModel.Row(app: cmux, installed: true, version: nil),
                    isCmuxSocketSetUp: setUp
                ),
                expected
            )
        }
    }

    func testDictationOnlyTerminalsAreYellowWhenInstalled() {
        for slug in ["warp", "wezterm", "kitty", "alacritty", "hyper", "tabby", "rio"] {
            let app = XCTUnwrapApp(slug)
            XCTAssertEqual(
                TerminalAppsSettingsModel.dot(
                    for: TerminalAppsSettingsModel.Row(app: app, installed: true, version: nil),
                    isCmuxSocketSetUp: true
                ),
                .yellow,
                "\(slug): installed dictation-only is yellow even with every gate clear"
            )
        }
    }

    func testUserAddedAppsAreYellowWhenInstalled() {
        let app = TerminalAppsSettingsModel.descriptor(
            for: UserTerminalApp(bundleID: "dev.some.Editor", displayName: "Editor")
        )
        XCTAssertEqual(
            TerminalAppsSettingsModel.dot(
                for: TerminalAppsSettingsModel.Row(app: app, installed: true, version: "1.0"),
                isCmuxSocketSetUp: true
            ),
            .yellow,
            "an added app gets dictation only, never a green dot"
        )
    }

    /// The pane's one status sentence per dot (owner decision fixes the exact
    /// copy; the dot's meaning lives in the pane, never in a legend).
    func testTerminalSentences() {
        XCTAssertEqual(
            SettingsStatusDot.green.terminalSentence,
            "Installed. Dictation, session join and screen context."
        )
        XCTAssertEqual(
            SettingsStatusDot.yellow.terminalSentence,
            "Installed. Dictation only."
        )
        XCTAssertEqual(SettingsStatusDot.grey.terminalSentence, "Not installed.")
    }

    // MARK: - Capability verdicts

    func testGhosttyCapabilityVerdictsFollowTheFloor() {
        let ghostty = XCTUnwrapApp("ghostty")
        let good = TerminalAppsSettingsModel.capabilityVerdicts(
            for: TerminalAppsSettingsModel.Row(app: ghostty, installed: true, version: "1.4.1"),
            isCmuxSocketSetUp: false
        )
        XCTAssertTrue(good.join)
        XCTAssertTrue(good.screen)
        XCTAssertNil(good.joinReason)
        XCTAssertNil(good.screenReason)

        let old = TerminalAppsSettingsModel.capabilityVerdicts(
            for: TerminalAppsSettingsModel.Row(app: ghostty, installed: true, version: "1.3"),
            isCmuxSocketSetUp: false
        )
        XCTAssertFalse(old.join)
        XCTAssertFalse(old.screen)
        XCTAssertEqual(old.joinReason, "Ghostty 1.4 or newer needed.")
        XCTAssertEqual(old.screenReason, "Ghostty 1.4 or newer needed.")
    }

    func testCmuxCapabilityVerdictsFollowSocketSetup() {
        let cmux = XCTUnwrapApp("cmux")
        let ready = TerminalAppsSettingsModel.capabilityVerdicts(
            for: TerminalAppsSettingsModel.Row(app: cmux, installed: true, version: nil),
            isCmuxSocketSetUp: true
        )
        XCTAssertTrue(ready.join)
        XCTAssertTrue(ready.screen)

        let pending = TerminalAppsSettingsModel.capabilityVerdicts(
            for: TerminalAppsSettingsModel.Row(app: cmux, installed: true, version: nil),
            isCmuxSocketSetUp: false
        )
        XCTAssertFalse(pending.join)
        XCTAssertFalse(pending.screen)
        XCTAssertEqual(pending.joinReason, TerminalAppCatalog.cmuxSocketReason)
        XCTAssertEqual(pending.screenReason, TerminalAppCatalog.cmuxSocketReason)
    }

    func testPlainTerminalsAndUserAppsAreDictationOnly() {
        let iterm = XCTUnwrapApp("iterm2")
        let full = TerminalAppsSettingsModel.capabilityVerdicts(
            for: TerminalAppsSettingsModel.Row(app: iterm, installed: true, version: nil),
            isCmuxSocketSetUp: false
        )
        XCTAssertTrue(full.join)
        XCTAssertTrue(full.screen)

        for slug in ["warp", "wezterm", "kitty", "alacritty", "hyper", "tabby", "rio"] {
            let app = XCTUnwrapApp(slug)
            let verdicts = TerminalAppsSettingsModel.capabilityVerdicts(
                for: TerminalAppsSettingsModel.Row(app: app, installed: true, version: nil),
                isCmuxSocketSetUp: true
            )
            XCTAssertFalse(verdicts.join, "\(slug) never joins")
            XCTAssertFalse(verdicts.screen, "\(slug) never gets screen reads")
            XCTAssertNotNil(verdicts.joinReason, "\(slug) states why join is absent")
            XCTAssertNotNil(verdicts.screenReason, "\(slug) states why screen is absent")
        }
    }

    // MARK: - Rows and installed detection

    func testRowDetectsThroughAnyChannelBundleID() {
        let store = makeStore()
        // Warp answers only on its Preview channel bundle id.
        let model = makeModel(store: store, installedVersions: ["dev.warp.Warp-Preview": "1.0"])
        let warp = XCTUnwrapApp("warp")
        let row = model.row(for: warp)
        XCTAssertTrue(row.installed, "any of Warp's channel bundle ids counts as installed")
        XCTAssertEqual(row.version, "1.0")
        XCTAssertEqual(model.dot(for: warp), .yellow)
    }

    func testRowReadsVersionFromTheMatchingBundle() {
        let store = makeStore()
        let model = makeModel(store: store, installedVersions: [
            "com.mitchellh.ghostty": "1.4.2",
        ])
        let ghostty = XCTUnwrapApp("ghostty")
        XCTAssertTrue(model.row(for: ghostty).installed)
        XCTAssertEqual(model.dot(for: ghostty), .green)
    }

    func testTerminalAppsListBuiltInsThenUserAppsInStoredOrder() {
        let store = makeStore()
        store.userTerminalApps = [
            UserTerminalApp(bundleID: "dev.two.App", displayName: "Two"),
            UserTerminalApp(bundleID: "dev.one.App", displayName: "One"),
        ]
        let model = makeModel(store: store)
        XCTAssertEqual(
            model.terminalApps.map(\.slug),
            TerminalAppCatalog.builtIn.map(\.slug) + ["dev-two-app", "dev-one-app"],
            "user apps follow the built-ins in the order they were added"
        )
    }

    // MARK: - Add / remove

    func testAddUserAppPersistsAndDetects() {
        let store = makeStore()
        let model = makeModel(store: store, installedVersions: ["dev.some.Editor": "2.0"])
        XCTAssertTrue(model.addUserApp(bundleID: " dev.some.Editor ", displayName: "  "))
        // Whitespace-trimmed on both fields; the name fell back to the bundle
        // id's last component because the capture was blank.
        XCTAssertEqual(
            store.userTerminalApps, [UserTerminalApp(bundleID: "dev.some.Editor", displayName: "Editor")]
        )
        let descriptor = TerminalAppsSettingsModel.descriptor(for: store.userTerminalApps[0])
        XCTAssertTrue(model.row(for: descriptor).installed)
        XCTAssertEqual(model.dot(for: descriptor), .yellow)
    }

    func testAddUserAppRefusesBuiltInsDuplicatesAndEmpty() {
        let store = makeStore()
        store.userTerminalApps = [UserTerminalApp(bundleID: "dev.some.Editor", displayName: "Editor")]
        let model = makeModel(store: store)

        XCTAssertFalse(
            model.addUserApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty"),
            "a built-in's row already exists"
        )
        XCTAssertFalse(
            model.addUserApp(bundleID: "dev.warp.Warp-Stable", displayName: "Warp"),
            "built-in channel bundle ids are covered too"
        )
        XCTAssertFalse(
            model.addUserApp(bundleID: "dev.some.Editor", displayName: "Editor"),
            "an already-added app is refused"
        )
        XCTAssertFalse(model.addUserApp(bundleID: "  ", displayName: "Blank"))
        XCTAssertEqual(store.userTerminalApps.count, 1, "no refusal path may write")
    }

    func testRemoveUserAppDeletesTheRow() {
        let store = makeStore()
        store.userTerminalApps = [
            UserTerminalApp(bundleID: "dev.some.Editor", displayName: "Editor"),
            UserTerminalApp(bundleID: "dev.other.Editor", displayName: "Other"),
        ]
        let model = makeModel(store: store)
        model.removeUserApp(bundleID: "dev.some.Editor")
        XCTAssertEqual(
            store.userTerminalApps.map(\.bundleID), ["dev.other.Editor"],
            "removal sticks in settings"
        )
    }

    // MARK: - Slug and display name

    func testSlugDerivation() {
        XCTAssertEqual(TerminalAppsSettingsModel.slug(forBundleID: "com.microsoft.VSCode"), "com-microsoft-vscode")
        XCTAssertEqual(TerminalAppsSettingsModel.slug(forBundleID: "dev.some..app--x"), "dev-some-app-x")
        XCTAssertEqual(TerminalAppsSettingsModel.slug(forBundleID: "APP"), "app")
        XCTAssertEqual(TerminalAppsSettingsModel.slug(forBundleID: "..."), "app")
        XCTAssertEqual(TerminalAppsSettingsModel.slug(forBundleID: "a_b"), "a-b")
    }

    func testFallbackDisplayName() {
        XCTAssertEqual(
            TerminalAppsSettingsModel.fallbackDisplayName(forBundleID: "com.microsoft.VSCode"),
            "VSCode"
        )
        XCTAssertEqual(
            TerminalAppsSettingsModel.fallbackDisplayName(forBundleID: "single"),
            "single"
        )
    }

    // MARK: - Migration from terminal_apps.toml

    func testMigrationImportsNewEntriesOnce() {
        let first = UserTerminalAppsMigrator.migrate(
            tomlBundleIDs: ["dev.some.Editor", " dev.other.Editor ", ""],
            storedApps: [],
            defaults: defaults
        )
        XCTAssertEqual(first.map(\.bundleID), ["dev.some.Editor", "dev.other.Editor"])
        XCTAssertEqual(first.map(\.displayName), ["Editor", "Editor"])

        // Second run over the same TOML: nothing new, nothing duplicated.
        let second = UserTerminalAppsMigrator.migrate(
            tomlBundleIDs: ["dev.some.Editor", "dev.other.Editor"],
            storedApps: first,
            defaults: defaults
        )
        XCTAssertEqual(second, first)

        // A NEW id appended to the TOML is picked up on the next launch —
        // the file remains a working add-path.
        let third = UserTerminalAppsMigrator.migrate(
            tomlBundleIDs: ["dev.some.Editor", "dev.other.Editor", "dev.third.Editor"],
            storedApps: second,
            defaults: defaults
        )
        XCTAssertEqual(third.map(\.bundleID), ["dev.some.Editor", "dev.other.Editor", "dev.third.Editor"])
    }

    func testMigrationNeverResurrectsARemovedApp() {
        let imported = UserTerminalAppsMigrator.migrate(
            tomlBundleIDs: ["dev.some.Editor"], storedApps: [], defaults: defaults
        )
        XCTAssertEqual(imported.map(\.bundleID), ["dev.some.Editor"])

        // The user removes it in Settings; the TOML still lists it.
        let afterRemoval = UserTerminalAppsMigrator.migrate(
            tomlBundleIDs: ["dev.some.Editor"], storedApps: [], defaults: defaults
        )
        XCTAssertTrue(
            afterRemoval.isEmpty,
            "an id the user removed must not resurrect just because the TOML still lists it"
        )
    }

    func testMigrationSkipsBuiltInBundleIDs() {
        let migrated = UserTerminalAppsMigrator.migrate(
            tomlBundleIDs: ["com.mitchellh.ghostty", "com.googlecode.iterm2"],
            storedApps: [],
            defaults: defaults
        )
        XCTAssertTrue(migrated.isEmpty, "built-ins already have rows; importing them would duplicate")
    }
}

/// Test-local unwrap over the built-in catalog, so a missing slug fails with
/// the slug's name rather than a force-unwrap line number.
private func XCTUnwrapApp(_ slug: String) -> TerminalAppDescriptor {
    guard let app = TerminalAppCatalog.builtIn.first(where: { $0.slug == slug }) else {
        fatalError("no built-in terminal named \(slug)")
    }
    return app
}
