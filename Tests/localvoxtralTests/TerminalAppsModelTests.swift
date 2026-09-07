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
    /// Constructs then sweeps, the same two steps a Settings open performs
    /// (the model's construction deliberately runs no lookups — see
    /// `testConstructionPerformsNoLaunchServicesLookups`).
    private func makeModel(
        store: SettingsStore,
        installedVersions: [String: String] = [:],
        isCmuxSocketSetUp: @escaping @Sendable () -> Bool = { false }
    ) -> TerminalAppsSettingsModel {
        let model = TerminalAppsSettingsModel(
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
        model.refreshInstalledState()
        return model
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

    /// iTerm2 and Terminal.app join (and read their TTY) through AppleScript,
    /// so the FIRST join prompts for the Automation permission. The pane
    /// states that in the Session join row's value — never via a TCC probe,
    /// which would itself prompt (docs/agent/invariants.md). The dot stays
    /// green: installed + supported is still true.
    func testAppleScriptJoinersStateTheAutomationPermissionInTheirJoinRow() {
        for slug in TerminalAppCatalog.appleScriptJoinSlugs {
            let app = XCTUnwrapApp(slug)
            let verdicts = TerminalAppsSettingsModel.capabilityVerdicts(
                for: TerminalAppsSettingsModel.Row(app: app, installed: true, version: nil),
                isCmuxSocketSetUp: false
            )
            XCTAssertTrue(verdicts.join, "\(slug) supports the join")
            XCTAssertNil(verdicts.joinReason, "stating a reason would read as a No")
            XCTAssertEqual(
                verdicts.joinValueText,
                TerminalAppCatalog.appleScriptAutomationJoinText,
                "\(slug): the join row states the Automation prompt"
            )
            XCTAssertEqual(
                verdicts.joinValueText,
                "Yes, asks for Automation permission on first use"
            )
        }
    }

    /// Every other terminal keeps the plain values: "Yes" when supported
    /// (Ghostty at its floor, cmux with the socket set up), "No" otherwise.
    func testNonAppleScriptJoinersKeepPlainJoinValueText() {
        let ghostty = XCTUnwrapApp("ghostty")
        XCTAssertEqual(
            TerminalAppsSettingsModel.capabilityVerdicts(
                for: TerminalAppsSettingsModel.Row(app: ghostty, installed: true, version: "1.4"),
                isCmuxSocketSetUp: false
            ).joinValueText,
            "Yes"
        )
        let cmux = XCTUnwrapApp("cmux")
        XCTAssertEqual(
            TerminalAppsSettingsModel.capabilityVerdicts(
                for: TerminalAppsSettingsModel.Row(app: cmux, installed: true, version: nil),
                isCmuxSocketSetUp: true
            ).joinValueText,
            "Yes"
        )
        for slug in ["warp", "wezterm"] {
            XCTAssertEqual(
                TerminalAppsSettingsModel.capabilityVerdicts(
                    for: TerminalAppsSettingsModel.Row(app: XCTUnwrapApp(slug), installed: true, version: nil),
                    isCmuxSocketSetUp: true
                ).joinValueText,
                "No",
                "\(slug): dictation-only reads No"
            )
        }
    }

    // MARK: - Rows and installed detection

    /// The LaunchServices sweep runs ONCE per Settings open, in the window's
    /// `onAppear` — not at construction. A `TerminalAppsSettingsModel` is
    /// also built for every discarded `SettingsView` value SwiftUI creates
    /// while re-evaluating the scene, so a constructor sweep would run the
    /// lookups far more than once per open (PR review finding).
    func testConstructionPerformsNoLaunchServicesLookups() {
        let store = makeStore()
        let counter = SendableCounter()
        let model = TerminalAppsSettingsModel(
            settings: store,
            applicationURLForBundleID: { _ in
                counter.increment()
                return nil
            },
            bundleShortVersion: { _ in nil },
            isCmuxSocketSetUp: { false }
        )
        XCTAssertEqual(
            counter.count, 0,
            "constructing the model must not sweep; the Settings open does that"
        )
        // The per-open refresh is the sweep's single home: one lookup per
        // bundle id, exactly once.
        model.refreshInstalledState()
        XCTAssertEqual(
            counter.count,
            Set(TerminalAppCatalog.builtIn.flatMap(\.detectionBundleIDs)).count,
            "the sweep performs exactly one lookup per distinct bundle id"
        )
        model.refreshInstalledState()
        XCTAssertEqual(
            counter.count,
            Set(TerminalAppCatalog.builtIn.flatMap(\.detectionBundleIDs)).count * 2,
            "an explicit re-run (window reopen, add/remove) sweeps again — the cache is per open, not forever"
        )
    }

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
        let outcome = model.addUserApp(bundleID: " dev.some.Editor ", displayName: "  ")
        XCTAssertTrue(outcome.added)
        XCTAssertNil(outcome.refusalSentence)
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
            model.addUserApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty").added,
            "a built-in's row already exists"
        )
        XCTAssertEqual(
            model.addUserApp(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty").refusalSentence,
            TerminalAppsSettingsModel.AddUserAppRefusal.coveredByBuiltInRow
        )
        XCTAssertFalse(
            model.addUserApp(bundleID: "dev.warp.Warp-Stable", displayName: "Warp").added,
            "built-in channel bundle ids are covered too"
        )
        XCTAssertFalse(
            model.addUserApp(bundleID: "dev.some.Editor", displayName: "Editor").added,
            "an already-added app is refused"
        )
        XCTAssertEqual(
            model.addUserApp(bundleID: "dev.some.Editor", displayName: "Editor").refusalSentence,
            TerminalAppsSettingsModel.AddUserAppRefusal.alreadyAdded
        )
        XCTAssertFalse(model.addUserApp(bundleID: "  ", displayName: "Blank").added)
        XCTAssertEqual(store.userTerminalApps.count, 1, "no refusal path may write")
    }

    /// A pane's identity is its slug (`SettingsTab.terminal`), so a user app
    /// whose slug collides with a built-in's would shadow that pane, and one
    /// colliding with another user app's would render two panes under one
    /// id. Both refusals surface ONE sentence — the pane-name-taken line.
    func testAddUserAppRefusesSlugCollisions() {
        let store = makeStore()
        let model = makeModel(store: store)

        // "ghostty" lowercases to the built-in Ghostty pane's slug.
        let builtInCollision = model.addUserApp(bundleID: "Ghostty", displayName: "Ghostty")
        XCTAssertFalse(builtInCollision.added, "a slug equal to a built-in's would shadow its pane")
        XCTAssertEqual(
            builtInCollision.refusalSentence,
            TerminalAppsSettingsModel.AddUserAppRefusal.paneNameTaken
        )
        XCTAssertEqual(
            builtInCollision.refusalSentence,
            "Another terminal already uses that pane name."
        )

        // Two bundle ids can derive the same slug ("dev.some.app" and
        // "dev_some_app" both give "dev-some-app").
        XCTAssertTrue(model.addUserApp(bundleID: "dev.some.app", displayName: "Some App").added)
        let userCollision = model.addUserApp(bundleID: "dev_some_app", displayName: "Also Some")
        XCTAssertFalse(
            userCollision.added,
            "a slug equal to another user app's would render two panes under one id"
        )
        XCTAssertEqual(
            userCollision.refusalSentence,
            TerminalAppsSettingsModel.AddUserAppRefusal.paneNameTaken
        )
        XCTAssertEqual(
            store.userTerminalApps.map(\.bundleID),
            ["dev.some.app"],
            "no refusal path may write"
        )
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
        let first = UserTerminalAppsMigrator.planImport(
            tomlBundleIDs: ["dev.some.Editor", " dev.other.Editor ", ""],
            storedApps: [],
            defaults: defaults
        )
        XCTAssertEqual(first.additions.map(\.bundleID), ["dev.some.Editor", "dev.other.Editor"])
        XCTAssertEqual(first.additions.map(\.displayName), ["Editor", "Editor"])

        // Applying the plan (the caller persists the list, then records):
        var stored = [UserTerminalApp]()
        stored += first.additions
        UserTerminalAppsMigrator.record(first, defaults: defaults)

        // Second run over the same TOML: nothing new, nothing duplicated.
        let second = UserTerminalAppsMigrator.planImport(
            tomlBundleIDs: ["dev.some.Editor", "dev.other.Editor"],
            storedApps: stored,
            defaults: defaults
        )
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(stored.map(\.bundleID), first.additions.map(\.bundleID))

        // A NEW id appended to the TOML is picked up on the next launch —
        // the file remains a working add-path.
        let third = UserTerminalAppsMigrator.planImport(
            tomlBundleIDs: ["dev.some.Editor", "dev.other.Editor", "dev.third.Editor"],
            storedApps: stored,
            defaults: defaults
        )
        XCTAssertEqual(
            third.additions.map(\.bundleID), ["dev.third.Editor"],
            "only the genuinely new id imports"
        )
    }

    /// A bundle id listed TWICE in the TOML imports once: `newIDs` is
    /// deduped against itself, preserving order (PR review finding — it was
    /// only deduped against the known ids).
    func testMigrationDeduplicatesRepeatedTomlEntries() {
        let plan = UserTerminalAppsMigrator.planImport(
            tomlBundleIDs: ["dev.some.Editor", "dev.some.Editor", "dev.other.Editor", "dev.some.Editor"],
            storedApps: [],
            defaults: defaults
        )
        XCTAssertEqual(
            plan.additions.map(\.bundleID),
            ["dev.some.Editor", "dev.other.Editor"],
            "a repeated TOML id must import exactly once, in first-seen order"
        )
        XCTAssertEqual(plan.importedBundleIDs, ["dev.some.Editor", "dev.other.Editor"])
    }

    /// The migration is transactional: planning writes NOTHING — the caller
    /// persists the stored list FIRST and records the ledger SECOND, so a
    /// crash between the two writes re-imports on the next launch rather
    /// than silently dropping the apps.
    func testMigrationPlanWritesNothingUntilRecorded() {
        let plan = UserTerminalAppsMigrator.planImport(
            tomlBundleIDs: ["dev.some.Editor"],
            storedApps: [],
            defaults: defaults
        )
        XCTAssertNil(
            defaults.stringArray(forKey: UserTerminalAppsMigrator.importedBundleIDsKey),
            "planning must not write the ledger; only record(_:) does, after the list"
        )
        XCTAssertFalse(plan.isEmpty)
        UserTerminalAppsMigrator.record(plan, defaults: defaults)
        XCTAssertEqual(
            defaults.stringArray(forKey: UserTerminalAppsMigrator.importedBundleIDsKey),
            ["dev.some.Editor"]
        )
        // Recording an empty plan is a no-op.
        UserTerminalAppsMigrator.record(
            UserTerminalAppsMigrator.Plan(additions: [], importedBundleIDs: []),
            defaults: defaults
        )
        XCTAssertEqual(
            defaults.stringArray(forKey: UserTerminalAppsMigrator.importedBundleIDsKey),
            ["dev.some.Editor"]
        )
    }

    func testMigrationNeverResurrectsARemovedApp() {
        let first = UserTerminalAppsMigrator.planImport(
            tomlBundleIDs: ["dev.some.Editor"], storedApps: [], defaults: defaults
        )
        UserTerminalAppsMigrator.record(first, defaults: defaults)

        // The user removes it in Settings; the TOML still lists it. The
        // removal is recorded in the removed-ids ledger at removal time.
        let store = makeStore()
        store.userTerminalApps += first.additions
        store.removeUserTerminalApp(bundleID: "dev.some.Editor")

        let afterRemoval = UserTerminalAppsMigrator.planImport(
            tomlBundleIDs: ["dev.some.Editor"],
            storedApps: store.userTerminalApps,
            defaults: defaults
        )
        XCTAssertTrue(
            afterRemoval.isEmpty,
            "an id the user removed must not resurrect just because the TOML still lists it"
        )
    }

    /// The no-resurrection rule must survive a LOST imported-ids ledger
    /// (defaults key wiped, or a non-array value left behind): removals are
    /// recorded in their OWN ledger at removal time, not inferred from what
    /// was imported.
    func testMigrationRemovedAppStaysGoneWhenTheImportedLedgerIsLost() {
        let first = UserTerminalAppsMigrator.planImport(
            tomlBundleIDs: ["dev.some.Editor"], storedApps: [], defaults: defaults
        )
        UserTerminalAppsMigrator.record(first, defaults: defaults)

        let store = makeStore()
        store.userTerminalApps += first.additions
        store.removeUserTerminalApp(bundleID: "dev.some.Editor")

        // The imported-ids ledger is lost entirely…
        defaults.removeObject(forKey: UserTerminalAppsMigrator.importedBundleIDsKey)
        // …and the relaunch migration still must not resurrect the app.
        let relaunch = UserTerminalAppsMigrator.planImport(
            tomlBundleIDs: ["dev.some.Editor"],
            storedApps: store.userTerminalApps,
            defaults: defaults
        )
        XCTAssertTrue(
            relaunch.isEmpty,
            "a lost imported-ids ledger must not resurrect a user-removed app the TOML still lists"
        )
        // A non-array value left in the ledger key reads as empty, never as a
        // crash or a wildcard.
        defaults.set("not an array", forKey: UserTerminalAppsMigrator.importedBundleIDsKey)
        let afterCorruption = UserTerminalAppsMigrator.planImport(
            tomlBundleIDs: ["dev.some.Editor"],
            storedApps: store.userTerminalApps,
            defaults: defaults
        )
        XCTAssertTrue(
            afterCorruption.isEmpty,
            "a corrupt imported-ids ledger reads as empty and still respects recorded removals"
        )
    }

    /// Re-adding an app clears its recorded removal: a later removal
    /// re-records it, and the two ledgers never disagree with the list.
    func testReaddingAnAppClearsItsRecordedRemoval() {
        let store = makeStore()
        store.userTerminalApps = [UserTerminalApp(bundleID: "dev.some.Editor", displayName: "Editor")]
        store.removeUserTerminalApp(bundleID: "dev.some.Editor")
        XCTAssertEqual(
            defaults.stringArray(forKey: UserTerminalAppsMigrator.removedBundleIDsKey),
            ["dev.some.Editor"]
        )
        store.addUserTerminalApp(UserTerminalApp(bundleID: "dev.some.Editor", displayName: "Editor"))
        XCTAssertEqual(
            defaults.stringArray(forKey: UserTerminalAppsMigrator.removedBundleIDsKey),
            [],
            "re-adding is a fresh start for the removal ledger"
        )
    }

    func testMigrationSkipsBuiltInBundleIDs() {
        let migrated = UserTerminalAppsMigrator.planImport(
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

/// Mutex-backed counter: the LaunchServices seam is `@Sendable`, so a plain
/// captured var cannot be mutated from it under strict concurrency.
private final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
