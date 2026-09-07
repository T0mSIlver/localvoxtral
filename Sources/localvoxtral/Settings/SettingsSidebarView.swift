import AppKit
import SwiftUI

/// Chrome (display copy, symbol, tint, AX identity) for each Settings tab.
///
/// The raw values are a contract with the AX drills — `scripts/ui-smoke.sh` and
/// `scripts/capture-readme-assets.sh` press `settings.tab.<rawValue>` and scope
/// their content asserts to `settings.pane.<rawValue>` — so the display names
/// here may change freely, the raw values may not.
extension SettingsTab {
    var title: String {
        switch kind {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .endpoints: return "Engines"
        case .textProcessing: return "Text Processing"
        case .integrationsContext: return "Context"
        case .integrationsClaude: return "Claude Code"
        case .integrationsOpencode: return "opencode"
        case .integrationsHerdr: return "herdr"
        case .terminal: return terminalApp?.displayName ?? "Terminal"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch kind {
        case .general: return "gearshape.fill"
        case .dictation: return "mic.fill"
        case .endpoints: return "cpu"
        case .textProcessing: return "text.badge.checkmark"
        case .integrationsContext: return "checklist"
        case .integrationsClaude: return "terminal.fill"
        case .integrationsOpencode: return "chevron.left.forwardslash.chevron.right"
        case .integrationsHerdr: return "rectangle.split.2x1"
        case .terminal: return "terminal"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .general: return Color(nsColor: .systemGray)
        case .dictation: return Color(nsColor: .systemRed)
        case .endpoints: return Color(nsColor: .systemBlue)
        case .textProcessing: return Color(nsColor: .systemPurple)
        case .integrationsContext: return Color(nsColor: .systemTeal)
        case .integrationsClaude: return Color(nsColor: .systemOrange)
        case .integrationsOpencode: return Color(nsColor: .systemMint)
        case .integrationsHerdr: return Color(nsColor: .systemIndigo)
        case .terminal: return Color(nsColor: .systemGray)
        case .about: return Color(nsColor: .systemGray)
        }
    }

    /// AX identity of the sidebar row that selects this tab.
    var accessibilityIdentifier: String { "settings.tab.\(rawValue)" }

    /// AX identity of the scrolling pane content for this tab. The drills scope
    /// their content asserts to this subtree, so a sidebar row's label can never
    /// vacuously satisfy a pane assert.
    var paneAccessibilityIdentifier: String { "settings.pane.\(rawValue)" }
}

enum SettingsSidebarMetrics {
    static let width: CGFloat = 208
    /// Clears the traffic lights: the window uses a transparent, full-size
    /// content view, so the first row would otherwise sit under them.
    static let topInset: CGFloat = 28
    static let rowHeight: CGFloat = 34
    static let rowCornerRadius: CGFloat = 8
    static let horizontalInset: CGFloat = 10
    /// Vertical breathing room around a section header. Sides match the rows'
    /// horizontal padding so the caps text aligns with the icon tiles' edge.
    static let sectionHeaderHorizontalPadding: CGFloat = 8
    static let sectionHeaderVerticalPadding: CGFloat = 8
}

/// The sidebar rendering of `SettingsStatusDot` (the model-side enum lives
/// with its derivations in `TerminalAppsModel.swift`; only the color is a
/// view concern).
extension SettingsStatusDot {
    var color: Color {
        switch self {
        case .green: return Color(nsColor: .systemGreen)
        case .yellow: return Color(nsColor: .systemYellow)
        case .grey: return Color(nsColor: .systemGray)
        }
    }
}

/// Hand-rolled sidebar: plain `Button` rows rather than `List`/`NavigationSplitView`.
///
/// Deliberate (design decision, 2026-07-27): the split-view containers bring a
/// sidebar-collapse toolbar button that can only be removed with private-API
/// hacks, and their rows surface to accessibility as table cells. Plain buttons
/// keep the window chrome under our control and give the AX drills a stable
/// `AXButton` + identifier to press.
///
/// Sections (owner decision, 2026-09-07, modelled on CodexBar's Providers
/// group): the main panes, then a small-caps grey **Integrations** header over
/// one row per harness, then **Terminals** over one row per terminal plus the
/// Add app… row. Rows keep the row idiom — icon tile, name, trailing dot.
struct SettingsSidebarView: View {
    @Binding var selection: SettingsTab
    /// Full Terminals section list (built-ins + user-added), from
    /// `TerminalAppsSettingsModel.terminalApps`.
    let terminalApps: [TerminalAppDescriptor]
    /// The dot a row trails, or nil for rows without a status (the main panes,
    /// About, Add app…).
    let statusDot: (SettingsTab) -> SettingsStatusDot?
    /// Opens the application picker and adds the chosen app (Terminals →
    /// Add app…). Owned here because the row lives in the sidebar.
    let addTerminalApp: () -> Void

    /// One short line when an Add app… attempt was refused (duplicate,
    /// built-in, unreadable bundle). The log carries the detail; the sidebar
    /// never shows more than a sentence (owner rule).
    @Binding var addAppMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Terminals + Integrations can outgrow the window height, so the
            // sections scroll and the meta rows stay pinned below.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsTab.primarySidebarItems, id: \.self) { tab in
                        SettingsSidebarRow(
                            tab: tab,
                            isSelected: selection == tab,
                            dot: statusDot(tab)
                        ) {
                            selection = tab
                        }
                    }

                    SettingsSidebarSectionHeader(title: "Integrations")

                    ForEach(SettingsTab.integrationsSidebarItems, id: \.self) { tab in
                        SettingsSidebarRow(
                            tab: tab,
                            isSelected: selection == tab,
                            dot: statusDot(tab)
                        ) {
                            selection = tab
                        }
                    }

                    SettingsSidebarSectionHeader(title: "Terminals")

                    ForEach(terminalApps.map(SettingsTab.terminal), id: \.self) { tab in
                        SettingsSidebarRow(
                            tab: tab,
                            isSelected: selection == tab,
                            dot: statusDot(tab)
                        ) {
                            selection = tab
                        }
                    }

                    SettingsSidebarAddAppRow(action: addTerminalApp)
                }
                .padding(.horizontal, SettingsSidebarMetrics.horizontalInset)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity, alignment: .top)

            if let addAppMessage {
                Text(addAppMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsSidebarMetrics.horizontalInset + 4)
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.metaSidebarItems, id: \.self) { tab in
                    SettingsSidebarRow(
                        tab: tab,
                        isSelected: selection == tab,
                        dot: statusDot(tab)
                    ) {
                        selection = tab
                    }
                }

                SettingsSidebarVersionFooter()
            }
            .padding(.horizontal, SettingsSidebarMetrics.horizontalInset)
        }
        .padding(.top, SettingsSidebarMetrics.topInset)
        .padding(.bottom, 12)
        .frame(width: SettingsSidebarMetrics.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsSidebarBackground())
    }
}

/// Small caps grey section header, CodexBar's "Providers" style (owner
/// decision, 2026-09-07): the title keeps its natural case and the font's
/// small-caps variant renders it — not `.uppercased()`, whose full-height
/// caps read as shouting next to 13pt row titles.
private struct SettingsSidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold).smallCaps())
            .foregroundStyle(.secondary)
            .padding(.horizontal, SettingsSidebarMetrics.sectionHeaderHorizontalPadding)
            .padding(.vertical, SettingsSidebarMetrics.sectionHeaderVerticalPadding)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let dot: SettingsStatusDot?
    let action: () -> Void

    @State private var isHovering = false

    private var fillStyle: Color {
        if isSelected {
            return Color(nsColor: .selectedContentBackgroundColor)
        }
        if isHovering {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }

    private var labelStyle: Color {
        isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SettingsSidebarIconTile(systemImage: tab.systemImage, tint: tab.tint)

                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(labelStyle)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let dot {
                    Circle()
                        .fill(dot.color)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: SettingsSidebarMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(
                    cornerRadius: SettingsSidebarMetrics.rowCornerRadius,
                    style: .continuous
                )
                .fill(fillStyle)
            }
            .contentShape(
                RoundedRectangle(
                    cornerRadius: SettingsSidebarMetrics.rowCornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        // No focus ring on sidebar rows (owner review, 2026-09-07): when the
        // window becomes key, SwiftUI hands first-responder to the FIRST row
        // (General), which then draws a blue ring while another row is
        // selected. Disabling only the focus EFFECT keeps the button a real,
        // keyboard-navigable, AX-pressable button — it just never paints the
        // ring. Selection is already shown by the row's own fill.
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(tab.accessibilityIdentifier)
    }
}

/// The Terminals section's last row (owner decision, 2026-09-07): opens the
/// application picker. Same idiom as the tab rows — icon tile, one word — but
/// no dot and its own AX identity, since it selects no pane.
private struct SettingsSidebarAddAppRow: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SettingsSidebarIconTile(
                    systemImage: "plus",
                    tint: Color(nsColor: .systemGray)
                )

                Text("Add app…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: SettingsSidebarMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(
                    cornerRadius: SettingsSidebarMetrics.rowCornerRadius,
                    style: .continuous
                )
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
            }
            .contentShape(
                RoundedRectangle(
                    cornerRadius: SettingsSidebarMetrics.rowCornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .accessibilityLabel("Add app")
        .accessibilityIdentifier("settings.tab.terminals.addApp")
    }
}

private struct SettingsSidebarIconTile: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint)
            .frame(width: 22, height: 22)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.15), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }
}

private struct SettingsSidebarVersionFooter: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "dev"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    var body: some View {
        Text("v\(version) (\(build))")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }
}

/// `.sidebar` material, blended WITHIN the window.
///
/// `.behindWindow` is the standard macOS sidebar look and was the first choice,
/// but the hand-test on the field Mac (PR #199 review, finding 2) reported it
/// rendering as a flat solid fill in BOTH appearances — this window cannot
/// vibrate what sits behind it. `.withinWindow` is the documented fallback and
/// is the one that actually produces a material here, so it is what ships; the
/// swap is a one-line change either way, not a redesign.
private struct SettingsSidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.state = .followsWindowActiveState
        view.blendingMode = .withinWindow
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
