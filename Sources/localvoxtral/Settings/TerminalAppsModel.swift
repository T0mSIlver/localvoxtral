import AppKit
import Foundation

/// The status dot a sidebar row or a pane status line renders. The meanings
/// are fixed by the owner decision (2026-09-07, modelled on CodexBar):
///
/// - green: detected and set up — dictation joins will work.
/// - yellow: detected, but a setup step is pending (a plugin not installed, a
///   version floor not met, a socket not configured) — dictation only.
/// - grey: not installed / not detected.
enum SettingsStatusDot: Equatable, Sendable {
    case green
    case yellow
    case grey

    /// One pane sentence for TERMINAL rows (the owner decision fixes the exact
    /// copy; the dot's meaning lives in the pane, never in a legend).
    var terminalSentence: String {
        switch self {
        case .green: return "Installed. Dictation, session join and screen context."
        case .yellow: return "Installed. Dictation only."
        case .grey: return "Not installed."
        }
    }
}

/// One terminal the Settings → Terminals section has a row for.
///
/// Covers BOTH lists the section draws from — the built-in terminals
/// (`TerminalAppCatalog.builtIn`) and the user-added apps stored in settings —
/// because the row, the pane, and the dot derivation are the same job for
/// both; only capability breadth and removability differ.
struct TerminalAppDescriptor: Identifiable, Equatable, Hashable, Sendable {
    /// Stable fragment of the tab's raw value (`terminals.<slug>`) and the
    /// row's identity. Never localized, never renamed for built-ins.
    let slug: String
    let displayName: String
    /// Bundle IDs LaunchServices is asked for, in order; ANY hit = installed.
    /// A list rather than one id because Warp ships channel-suffixed bundle
    /// IDs (`dev.warp.Warp-Stable` / `-Preview` / `-Dev`, per the insertion
    /// detector's prefix list).
    let detectionBundleIDs: [String]
    /// The per-app capability story. See `TerminalCapabilities`.
    let capabilities: TerminalCapabilities
    /// True when the row can be removed from Settings (user-added apps only).
    let isUserAdded: Bool

    var id: String { slug }
}

/// What a terminal supports, as the Terminal pane renders it: three short
/// rows, each "Yes" or "No" with a one-line reason when No.
///
/// The join/screen answers mirror `TerminalScreenAllowlist` and the join
/// arms (owner decision 2026-07-22): Ghostty, iTerm2, Terminal.app and cmux
/// join; every other terminal is dictation-only. This type is a SETTINGS
/// DERIVATION ONLY — the runtime gates stay where they are (the allowlist,
/// the join resolver); if the two ever disagree the fix is here, not there.
struct TerminalCapabilities: Equatable, Hashable, Sendable {
    /// The reason a capability is absent, one line, e.g. "Ghostty 1.4 or
    /// newer needed." Nil when the capability is present.
    let joinRequirement: String?
    let screenRequirement: String?

    /// DYNAMIC gates the catalog cannot know: cmux's socket setup, Ghostty's
    /// installed version. Evaluated by `TerminalAppsSettingsModel`.
    enum DynamicGate: Equatable, Sendable {
        /// Ghostty's TTY join and AX grid read need ≥ 1.4.
        case ghosttyVersion(installed: String?)
        /// cmux joins only with the surface-join toggle on and a socket
        /// password stored (`CmuxSocketPasswordStore`).
        case cmuxSocketSetUp(enabled: Bool, passwordStored: Bool)
    }

    static func supportsEverything() -> TerminalCapabilities {
        TerminalCapabilities(joinRequirement: nil, screenRequirement: nil)
    }

    static func dictationOnly(reason: String) -> TerminalCapabilities {
        TerminalCapabilities(joinRequirement: reason, screenRequirement: reason)
    }
}

/// The built-in terminal list: one row each, in the owner-decided order.
enum TerminalAppCatalog {
    /// Ghostty's join floor, from the invariants doc (`AppleScriptTerminalTTYReader`
    /// needs Ghostty ≥ 1.4's focused terminal).
    static let ghosttyJoinFloor = (major: 1, minor: 4)

    /// The reason string the Ghostty rows carry below the join/screen rows
    /// when the floor is not met. Fixed by the owner decision's example.
    static let ghosttyVersionReason = "Ghostty 1.4 or newer needed."

    static let cmuxSocketReason =
        "Set cmux's socket to password mode, then save the same password in Claude Code."

    /// cmux's two-step setup doc, linked from the cmux pane.
    static let cmuxDocsURL = URL(
        string:
            "https://github.com/T0mSIlver/localvoxtral/blob/main/integrations/claude-code/README.md#which-terminal-am-i-dictating-into"
    )!

    /// The terminals whose session join (and TTY read) goes through
    /// AppleScript, so the FIRST join prompts for the Automation
    /// (AppleScript) permission. Their pane's Session join row carries
    /// `appleScriptAutomationJoinText` instead of a bare "Yes" — the dot
    /// stays green (installed + supported), and the app must never probe TCC
    /// to find out, because probing itself prompts (docs/agent/invariants.md).
    static let appleScriptJoinSlugs: Set<String> = ["iterm2", "apple-terminal"]

    /// The Session join row's value text for the AppleScript joiners above.
    /// Fixed by owner decision: state the prompt, keep the yes.
    static let appleScriptAutomationJoinText =
        "Yes, asks for Automation permission on first use"

    /// Owner-decided order (2026-09-07): join-capable terminals first, then
    /// the dictation-only list in the order `terminal_apps.toml` documented.
    static let builtIn: [TerminalAppDescriptor] = [
        TerminalAppDescriptor(
            slug: "ghostty",
            displayName: "Ghostty",
            detectionBundleIDs: [TerminalScreenAllowlist.ghosttyBundleID],
            capabilities: TerminalCapabilities(
                joinRequirement: nil, screenRequirement: nil
            ),
            isUserAdded: false
        ),
        TerminalAppDescriptor(
            slug: "iterm2",
            displayName: "iTerm2",
            detectionBundleIDs: [TerminalScreenAllowlist.iterm2BundleID],
            capabilities: .supportsEverything(),
            isUserAdded: false
        ),
        TerminalAppDescriptor(
            slug: "apple-terminal",
            displayName: "Terminal.app",
            detectionBundleIDs: [TerminalScreenAllowlist.appleTerminalBundleID],
            capabilities: .supportsEverything(),
            isUserAdded: false
        ),
        TerminalAppDescriptor(
            slug: "cmux",
            displayName: "cmux",
            detectionBundleIDs: [TerminalScreenAllowlist.cmuxBundleID],
            capabilities: .supportsEverything(),
            isUserAdded: false
        ),
        TerminalAppDescriptor(
            slug: "warp",
            displayName: "Warp",
            detectionBundleIDs: [
                "dev.warp.Warp-Stable", "dev.warp.Warp-Public", "dev.warp.Warp",
                "dev.warp.Warp-Preview", "dev.warp.Warp-Dev",
            ],
            capabilities: .dictationOnly(reason: "Not available in this terminal yet."),
            isUserAdded: false
        ),
        TerminalAppDescriptor(
            slug: "wezterm",
            displayName: "WezTerm",
            detectionBundleIDs: ["com.github.wez.wezterm"],
            capabilities: .dictationOnly(reason: "Not available in this terminal yet."),
            isUserAdded: false
        ),
        TerminalAppDescriptor(
            slug: "kitty",
            displayName: "kitty",
            detectionBundleIDs: ["net.kovidgoyal.kitty"],
            capabilities: .dictationOnly(reason: "Not available in this terminal yet."),
            isUserAdded: false
        ),
        TerminalAppDescriptor(
            slug: "alacritty",
            displayName: "Alacritty",
            detectionBundleIDs: ["org.alacritty"],
            capabilities: .dictationOnly(reason: "Not available in this terminal yet."),
            isUserAdded: false
        ),
        TerminalAppDescriptor(
            slug: "hyper",
            displayName: "Hyper",
            detectionBundleIDs: ["co.zeit.hyper"],
            capabilities: .dictationOnly(reason: "Not available in this terminal yet."),
            isUserAdded: false
        ),
        TerminalAppDescriptor(
            slug: "tabby",
            displayName: "Tabby",
            detectionBundleIDs: ["org.tabby"],
            capabilities: .dictationOnly(reason: "Not available in this terminal yet."),
            isUserAdded: false
        ),
        TerminalAppDescriptor(
            slug: "rio",
            displayName: "Rio",
            detectionBundleIDs: ["com.raphaelamorim.rio"],
            capabilities: .dictationOnly(reason: "Not available in this terminal yet."),
            isUserAdded: false
        ),
    ]

    /// Every bundle ID any built-in row detects with — the duplicate guard
    /// for user-added apps (a built-in's row already exists).
    static func isBuiltInDetectionBundleID(_ bundleID: String) -> Bool {
        builtIn.contains { $0.detectionBundleIDs.contains(bundleID) }
    }

    /// Dotted-numeric comparison for the Ghostty floor. A missing component
    /// reads as 0 (`1.4` == `1.4.0`); unparseable input reads as 0.0 and so
    /// never passes a floor — an unreadable version must not paint green.
    static func meetsGhosttyFloor(_ version: String?) -> Bool {
        guard let version else { return false }
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let major = parts.count > 0 ? parts[0] : 0
        let minor = parts.count > 1 ? parts[1] : 0
        if major != ghosttyJoinFloor.major { return major > ghosttyJoinFloor.major }
        return minor >= ghosttyJoinFloor.minor
    }
}

/// A user-added terminal app, persisted by `SettingsStore`.
///
/// The successor of a `terminal_apps.toml` entry (which is read once at
/// startup as a migration source and then left untouched): same effect on
/// insertion — the bundle is treated as terminal-like — plus a display name
/// and a pane it can be removed from.
struct UserTerminalApp: Codable, Equatable, Identifiable, Sendable {
    var bundleID: String
    var displayName: String

    var id: String { bundleID }
}

/// The Settings → Terminals model: installed-state rows, dots, capability
/// verdicts, and the user-added list.
///
/// Installed detection is LaunchServices only (`NSWorkspace
/// .urlForApplication(withBundleIdentifier:)`), never a running-process
/// check, and is cached per Settings open (owner decision). The LaunchServices
/// and Info.plist reads are injected so the whole derivation is testable
/// against fixtures — the real one is never exercised from tests.
@MainActor
@Observable
final class TerminalAppsSettingsModel {
    /// One rendered row: the descriptor plus its cached installed state.
    struct Row: Identifiable, Equatable, Sendable {
        let app: TerminalAppDescriptor
        let installed: Bool
        /// `CFBundleShortVersionString` of the first bundle that matched, when
        /// known. Only Ghostty's floor consults it today.
        let version: String?

        var id: String { app.slug }
    }

    private let settings: SettingsStore
    /// LaunchServices lookup seam. Returns the app's URL or nil.
    private let applicationURLForBundleID: @Sendable (String) -> URL?
    /// Reads `CFBundleShortVersionString` from an app bundle URL, or nil.
    private let bundleShortVersion: @Sendable (URL) -> String?
    private var installedCache: [String: Bool] = [:]
    private var versionCache: [String: String?] = [:]

    /// Whether cmux's app-side socket setup is complete (toggle on + password
    /// stored). Passed in rather than read here: both facts already have
    /// owners (`SettingsStore`, `ClaudeIntegrationSettingsModel`), and the
    /// Keychain must not be reached around. Deliberately NOT `@Sendable` —
    /// it reads MainActor state and is only ever called from this model's
    /// MainActor members.
    private let isCmuxSocketSetUp: () -> Bool

    init(
        settings: SettingsStore,
        applicationURLForBundleID: @escaping @Sendable (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        bundleShortVersion: @escaping @Sendable (URL) -> String? = { url in
            guard
                let info = Bundle(url: url),
                let version = info.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String
            else { return nil }
            return version
        },
        isCmuxSocketSetUp: @escaping () -> Bool = { false }
    ) {
        self.settings = settings
        self.applicationURLForBundleID = applicationURLForBundleID
        self.bundleShortVersion = bundleShortVersion
        self.isCmuxSocketSetUp = isCmuxSocketSetUp
    }

    /// (Re-)runs the LaunchServices lookups. The Settings window's `onAppear`
    /// calls it ONCE per open — the sweep must have exactly one home, because
    /// a `TerminalAppsSettingsModel` is also constructed for every discarded
    /// `SettingsView` value SwiftUI builds while re-evaluating the scene, and
    /// a constructor sweep would fire on each of those. Adding/removing a user
    /// app re-runs it so the new bundle id gets its (single) lookup. The
    /// cache lives for the window's lifetime: an app installed while the
    /// window was closed is seen on the next open.
    func refreshInstalledState() {
        var newInstalled: [String: Bool] = [:]
        var newVersions: [String: String?] = [:]
        for bundleID in Self.allDetectionBundleIDs(apps: terminalApps) {
            if let url = applicationURLForBundleID(bundleID) {
                newInstalled[bundleID] = true
                newVersions[bundleID] = bundleShortVersion(url)
            } else {
                newInstalled[bundleID] = false
                newVersions[bundleID] = nil
            }
        }
        installedCache = newInstalled
        versionCache = newVersions
    }

    /// The full Terminals section: built-ins in catalog order, then
    /// user-added apps in the order they were added.
    var terminalApps: [TerminalAppDescriptor] {
        TerminalAppCatalog.builtIn + settings.userTerminalApps.map(Self.descriptor(for:))
    }

    func row(for app: TerminalAppDescriptor) -> Row {
        let matched = app.detectionBundleIDs.first {
            installedCache[$0] == true
        }
        return Row(
            app: app,
            installed: matched != nil,
            version: matched.flatMap { versionCache[$0] ?? nil }
        )
    }

    var rows: [Row] {
        terminalApps.map(row(for:))
    }

    /// The sidebar dot for one terminal.
    func dot(for app: TerminalAppDescriptor) -> SettingsStatusDot {
        Self.dot(for: row(for: app), isCmuxSocketSetUp: isCmuxSocketSetUp())
    }

    /// Pure derivation, so the whole matrix is unit-testable without a
    /// SettingsStore: grey when not installed; green for the join-capable
    /// terminals with their dynamic gates satisfied; yellow otherwise.
    nonisolated static func dot(
        for row: Row,
        isCmuxSocketSetUp: Bool
    ) -> SettingsStatusDot {
        guard row.installed else { return .grey }
        switch row.app.slug {
        case "ghostty":
            return TerminalAppCatalog.meetsGhosttyFloor(row.version) ? .green : .yellow
        case "cmux":
            return isCmuxSocketSetUp ? .green : .yellow
        case "iterm2", "apple-terminal":
            return .green
        default:
            return .yellow
        }
    }

    /// The capability verdicts the Terminal pane renders, including the
    /// dynamic gates the static catalog cannot know.
    struct CapabilityVerdicts: Equatable, Sendable {
        let join: Bool
        let joinReason: String?
        /// The trailing text of the Session join row: "Yes", unless the join
        /// route needs a permission the user grants on first use (iTerm2 and
        /// Terminal.app join through AppleScript —
        /// `TerminalAppCatalog.appleScriptAutomationJoinText`).
        let joinValueText: String
        let screen: Bool
        let screenReason: String?
    }

    func capabilityVerdicts(for app: TerminalAppDescriptor) -> CapabilityVerdicts {
        Self.capabilityVerdicts(
            for: row(for: app), isCmuxSocketSetUp: isCmuxSocketSetUp())
    }

    nonisolated static func capabilityVerdicts(
        for row: Row,
        isCmuxSocketSetUp: Bool
    ) -> CapabilityVerdicts {
        let app = row.app
        switch app.slug {
        case "ghostty":
            if TerminalAppCatalog.meetsGhosttyFloor(row.version) {
                return CapabilityVerdicts(
                    join: true, joinReason: nil, joinValueText: "Yes",
                    screen: true, screenReason: nil
                )
            }
            return CapabilityVerdicts(
                join: false,
                joinReason: TerminalAppCatalog.ghosttyVersionReason,
                joinValueText: "No",
                screen: false,
                screenReason: TerminalAppCatalog.ghosttyVersionReason
            )
        case "cmux":
            let reason: String? = isCmuxSocketSetUp ? nil : TerminalAppCatalog.cmuxSocketReason
            return CapabilityVerdicts(
                join: reason == nil, joinReason: reason,
                joinValueText: reason == nil ? "Yes" : "No",
                screen: reason == nil, screenReason: reason
            )
        default:
            let joinSupported = app.capabilities.joinRequirement == nil
            return CapabilityVerdicts(
                join: joinSupported,
                joinReason: app.capabilities.joinRequirement,
                joinValueText: joinValueText(supported: joinSupported, slug: app.slug),
                screen: app.capabilities.screenRequirement == nil,
                screenReason: app.capabilities.screenRequirement
            )
        }
    }

    /// "Yes"/"No", except the AppleScript joiners state the Automation
    /// prompt in the value itself: the row still reads as a yes, the dot
    /// stays green, and no TCC probe ever runs to find out more.
    nonisolated private static func joinValueText(supported: Bool, slug: String) -> String {
        guard supported else { return "No" }
        return TerminalAppCatalog.appleScriptJoinSlugs.contains(slug)
            ? TerminalAppCatalog.appleScriptAutomationJoinText
            : "Yes"
    }

    // MARK: - User-added apps

    /// The outcome of an Add app… attempt: added, or refused with the ONE
    /// sentence the sidebar shows. The log carries the detail — never more
    /// than a sentence in chrome (owner rule).
    struct AddUserAppOutcome: Equatable, Sendable {
        let added: Bool
        let refusalSentence: String?

        static let added = AddUserAppOutcome(added: true, refusalSentence: nil)

        static func refused(_ sentence: String) -> AddUserAppOutcome {
            AddUserAppOutcome(added: false, refusalSentence: sentence)
        }
    }

    /// The refusal sentences, as constants so tests pin the exact copy.
    enum AddUserAppRefusal {
        static let blankBundleID = "That app has no readable bundle id."
        static let coveredByBuiltInRow = "A built-in terminal row already lists that app."
        static let alreadyAdded = "That app is already listed."
        static let paneNameTaken = "Another terminal already uses that pane name."
    }

    /// Adds a chosen app. Refuses a blank bundle id, an id a built-in row
    /// already covers, an already-added id, and — because a pane's identity
    /// is its slug (`SettingsTab.terminal`) — a slug that collides with a
    /// built-in's or another user app's: a colliding pane would shadow the
    /// row it shares an id with.
    @discardableResult
    func addUserApp(bundleID: String, displayName: String) -> AddUserAppOutcome {
        let id = bundleID.trimmed
        guard !id.isEmpty else {
            Log.config.notice("Refused to add a terminal app with no bundle id")
            return .refused(AddUserAppRefusal.blankBundleID)
        }
        guard !TerminalAppCatalog.isBuiltInDetectionBundleID(id) else {
            Log.config.notice(
                "Refused to add \(id, privacy: .public): a built-in terminal row already covers it"
            )
            return .refused(AddUserAppRefusal.coveredByBuiltInRow)
        }
        guard !settings.userTerminalApps.contains(where: { $0.bundleID == id }) else {
            Log.config.notice(
                "Refused to add \(id, privacy: .public): already in the added-apps list"
            )
            return .refused(AddUserAppRefusal.alreadyAdded)
        }
        let slug = Self.slug(forBundleID: id)
        guard !TerminalAppCatalog.builtIn.contains(where: { $0.slug == slug }) else {
            Log.config.notice(
                "Refused to add \(id, privacy: .public): its slug \(slug, privacy: .public) collides with a built-in terminal's pane"
            )
            return .refused(AddUserAppRefusal.paneNameTaken)
        }
        guard !settings.userTerminalApps.contains(where: {
            Self.slug(forBundleID: $0.bundleID) == slug
        }) else {
            Log.config.notice(
                "Refused to add \(id, privacy: .public): its slug \(slug, privacy: .public) collides with another added app's pane"
            )
            return .refused(AddUserAppRefusal.paneNameTaken)
        }
        let name = displayName.trimmed.isEmpty ? Self.fallbackDisplayName(forBundleID: id) : displayName.trimmed
        settings.addUserTerminalApp(UserTerminalApp(bundleID: id, displayName: name))
        Log.config.notice(
            "Added terminal app \(name, privacy: .public) (\(id, privacy: .public))"
        )
        refreshInstalledState()
        return .added
    }

    func removeUserApp(bundleID: String) {
        // The store records the removal in the migration ledger so the
        // launch-time terminal_apps.toml import cannot resurrect the id.
        settings.removeUserTerminalApp(bundleID: bundleID)
        Log.config.notice("Removed terminal app \(bundleID, privacy: .public)")
        refreshInstalledState()
    }

    /// The descriptor a stored user app renders as: dictation-only, removable.
    nonisolated static func descriptor(for app: UserTerminalApp) -> TerminalAppDescriptor {
        TerminalAppDescriptor(
            slug: slug(forBundleID: app.bundleID),
            displayName: app.displayName,
            detectionBundleIDs: [app.bundleID],
            capabilities: .dictationOnly(reason: "Added apps get dictation only."),
            isUserAdded: true
        )
    }

    /// Stable, URL-safe slug for a bundle id: lowercase, runs of anything
    /// else collapsed to one dash (`com.microsoft.VSCode` →
    /// `com-microsoft-vscode`). Two bundle ids differing only in case are
    /// effectively one app on macOS, so lowercasing cannot collide two rows
    /// that LaunchServices would tell apart.
    nonisolated static func slug(forBundleID bundleID: String) -> String {
        var slug = ""
        var lastWasDash = false
        for character in bundleID.lowercased() {
            if character.isLetter || character.isNumber {
                slug.append(character)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        return slug.isEmpty ? "app" : slug
    }

    /// A readable name when none was captured: the last dot-separated
    /// component of the bundle id (`com.microsoft.VSCode` → `VSCode`).
    nonisolated static func fallbackDisplayName(forBundleID bundleID: String) -> String {
        let components = bundleID.split(separator: ".")
        if let last = components.last, !last.isEmpty {
            return String(last)
        }
        return bundleID
    }

    private static func allDetectionBundleIDs(apps: [TerminalAppDescriptor]) -> [String] {
        apps.flatMap(\.detectionBundleIDs)
    }
}

/// One-time migration from `terminal_apps.toml` into the settings-stored
/// user-added apps (owner decision, 2026-09-07): the TOML is read ONCE per
/// startup, entries not already known are imported, and the FILE IS LEFT
/// UNTOUCHED — settings is authoritative from then on.
///
/// Removal must stick: an id the user removed from Settings must not
/// resurrect on the next launch just because the TOML still lists it. Two
/// ledgers hold that line — the ids that have EVER been imported
/// (`importedBundleIDsKey`) and the ids the user removed
/// (`removedBundleIDsKey`, written at removal time by `SettingsStore`). An
/// id in EITHER ledger is never re-imported, so a removed app stays gone
/// even if the imported-ids ledger is lost or unreadable. A NEW id appended
/// to the TOML is still picked up on the next launch — the file remains a
/// working add-path, only removal moves to the UI.
enum UserTerminalAppsMigrator {
    static let importedBundleIDsKey = "settings.user_terminal_apps_imported_bundle_ids"
    static let removedBundleIDsKey = "settings.user_terminal_apps_removed_bundle_ids"

    /// A computed import, applied by the CALLER in a fixed order: the stored
    /// list first, the imported-ids ledger second. A crash between the two
    /// writes leaves the ledger BEHIND the list, so the next launch sees the
    /// ids in the stored list and imports nothing; the reverse order would
    /// let the ledger alone make a lost list look already-imported, silently
    /// dropping the apps.
    struct Plan: Equatable {
        /// Entries to append to the stored list.
        let additions: [UserTerminalApp]
        /// The full replacement value for the imported-ids ledger, to be
        /// written only after the list was persisted.
        let importedBundleIDs: [String]

        var isEmpty: Bool { additions.isEmpty }
    }

    /// Reads both ledgers (a lost or non-array key reads as empty) and plans
    /// the import. Writes nothing — applying the plan is the caller's half
    /// of the transaction.
    static func planImport(
        tomlBundleIDs: [String],
        storedApps: [UserTerminalApp],
        defaults: UserDefaults
    ) -> Plan {
        planImport(
            tomlBundleIDs: tomlBundleIDs,
            storedApps: storedApps,
            importedBundleIDs: defaults.stringArray(forKey: importedBundleIDsKey) ?? [],
            removedBundleIDs: defaults.stringArray(forKey: removedBundleIDsKey) ?? []
        )
    }

    /// Pure over its inputs, so the migration's idempotence, dedup, and
    /// no-resurrection rules are unit-testable without a defaults store.
    static func planImport(
        tomlBundleIDs: [String],
        storedApps: [UserTerminalApp],
        importedBundleIDs: [String],
        removedBundleIDs: [String]
    ) -> Plan {
        let known = Set(storedApps.map(\.bundleID))
            .union(importedBundleIDs)
            .union(removedBundleIDs)
            .union(TerminalAppCatalog.builtIn.flatMap(\.detectionBundleIDs))

        // Deduped against `known` AND against itself, preserving order: a
        // bundle id listed twice in the TOML imports once.
        var seen = Set<String>()
        let newIDs = tomlBundleIDs
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
            .filter { !known.contains($0) }
            .filter { seen.insert($0).inserted }

        return Plan(
            additions: newIDs.map { bundleID in
                UserTerminalApp(
                    bundleID: bundleID,
                    displayName: TerminalAppsSettingsModel.fallbackDisplayName(forBundleID: bundleID)
                )
            },
            importedBundleIDs: importedBundleIDs + newIDs
        )
    }

    /// Records the ledger — call only AFTER the stored list was persisted.
    static func record(_ plan: Plan, defaults: UserDefaults) {
        guard !plan.isEmpty else { return }
        defaults.set(plan.importedBundleIDs, forKey: importedBundleIDsKey)
        Log.config.notice(
            "Imported \(plan.additions.count, privacy: .public) terminal app(s) from terminal_apps.toml"
        )
    }
}
