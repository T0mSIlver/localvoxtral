import SwiftUI

/// Identifies each Settings pane so navigation can be driven programmatically
/// (e.g. the onboarding "I run my own server" link jumps to Engines).
///
/// A struct, not a raw enum, since the owner decision (2026-09-07) gives every
/// TERMINAL its own pane and user-added terminals are runtime data: the
/// `kind` enum below is the fixed pane set, `.terminal` carries the specific
/// app. The raw values are a contract with the AX drills
/// (`scripts/ui-smoke.sh`, `scripts/capture-readme-assets.sh` press
/// `settings.tab.<rawValue>` and scope content asserts to
/// `settings.pane.<rawValue>`): the values for pre-existing panes NEVER
/// change, the retired `integrations` value must not come back, and each
/// terminal pane is `terminals.<slug>`.
struct SettingsTab: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, CaseIterable {
        case general
        case endpoints
        case dictation
        case textProcessing
        case integrationsContext = "integrations.context"
        case integrationsClaude = "integrations.claude"
        case integrationsOpencode = "integrations.opencode"
        case integrationsHerdr = "integrations.herdr"
        /// Raw value completed with the terminal row's slug — see `rawValue`.
        case terminal
        case about
    }

    let kind: Kind
    /// The terminal this pane is about. Nil for every non-terminal pane; set
    /// only through `SettingsTab.terminal(_:)`.
    let terminalApp: TerminalAppDescriptor?

    init(kind: Kind, terminalApp: TerminalAppDescriptor? = nil) {
        self.kind = kind
        self.terminalApp = terminalApp
    }

    /// Convenience: `SettingsTab(.general)` keeps the shape call sites had
    /// when this was an enum.
    init(_ kind: Kind) {
        self.init(kind: kind)
    }

    /// A terminal pane: one per terminal the app knows (built-in or
    /// user-added). Identity is the descriptor's slug, so a user app whose
    /// bundle id slug collides with a built-in cannot shadow it — the
    /// duplicate is refused at add time.
    static func terminal(_ app: TerminalAppDescriptor) -> SettingsTab {
        SettingsTab(kind: .terminal, terminalApp: app)
    }

    /// Every pane a static drill can name, in presentation order. User-added
    /// terminal panes are NOT here — they have no script-drilled contract.
    static var allKnownPanes: [SettingsTab] {
        primarySidebarItems
            + integrationsSidebarItems
            + TerminalAppCatalog.builtIn.map(terminal)
            + metaSidebarItems
    }

    var rawValue: String {
        switch kind {
        case .terminal:
            return "terminals.\(terminalApp?.slug ?? "")"
        default:
            return kind.rawValue
        }
    }
}

// MARK: - Sidebar sections

extension SettingsTab {
    /// Sidebar order, top section. Deliberately NOT the declaration order of
    /// the kind enum: raw values are frozen for the scripts, presentation
    /// order is not.
    static let primarySidebarItems: [SettingsTab] = [
        .general, .dictation, .endpoints, .textProcessing,
    ]

    /// The Integrations section (owner decision, 2026-09-07): one row per
    /// harness, each opening its own pane. The old single Integrations pane
    /// is gone; its `integrations` raw value is retired.
    static let integrationsSidebarItems: [SettingsTab] = [
        .integrationsContext, .integrationsClaude, .integrationsOpencode, .integrationsHerdr,
    ]

    /// Pinned to the bottom of the sidebar, under the spacer.
    static let metaSidebarItems: [SettingsTab] = [.about]

    /// Convenience accessors for the static panes, so call sites keep the
    /// `SettingsTab.general` shape they had when this was an enum.
    static let general = SettingsTab(.general)
    static let endpoints = SettingsTab(.endpoints)
    static let dictation = SettingsTab(.dictation)
    static let textProcessing = SettingsTab(.textProcessing)
    static let integrationsContext = SettingsTab(.integrationsContext)
    static let integrationsClaude = SettingsTab(.integrationsClaude)
    static let integrationsOpencode = SettingsTab(.integrationsOpencode)
    static let integrationsHerdr = SettingsTab(.integrationsHerdr)
    static let about = SettingsTab(.about)
}
