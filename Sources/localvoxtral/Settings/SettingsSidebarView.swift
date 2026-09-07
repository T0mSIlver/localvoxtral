import AppKit
import SwiftUI

/// Chrome (display copy, symbol, tint, AX identity) for each Settings tab.
///
/// The raw values are a contract with the AX drills — `scripts/ui-smoke.sh` and
/// `scripts/capture-readme-assets.sh` press `settings.tab.<rawValue>` and scope
/// their content asserts to `settings.pane.<rawValue>` — so the display names
/// here may change freely, the raw values may not.
extension SettingsTab {
    /// Sidebar order, top group. Deliberately NOT the declaration order of the
    /// enum: raw values are frozen for the scripts, presentation order is not.
    static let primarySidebarItems: [SettingsTab] = [
        .general, .dictation, .endpoints, .textProcessing, .context,
    ]

    /// Pinned to the bottom of the sidebar, under the spacer.
    static let metaSidebarItems: [SettingsTab] = [.about]

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .endpoints: return "Endpoints"
        case .textProcessing: return "Text Processing"
        case .context: return "Context"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Permissions and app-level behavior."
        case .dictation: return "How you start, stop, and see dictation."
        case .endpoints: return "Where speech recognition and polishing run."
        case .textProcessing: return "Replacements and LLM polishing of your transcript."
        case .context: return "What the polisher and Claude Code integration may see."
        case .about: return "Version, project, and diagnostics."
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .dictation: return "mic.fill"
        case .endpoints: return "cpu"
        case .textProcessing: return "text.badge.checkmark"
        case .context: return "terminal.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(nsColor: .systemGray)
        case .dictation: return Color(nsColor: .systemRed)
        case .endpoints: return Color(nsColor: .systemBlue)
        case .textProcessing: return Color(nsColor: .systemPurple)
        case .context: return Color(nsColor: .systemIndigo)
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
}

/// Hand-rolled sidebar: plain `Button` rows rather than `List`/`NavigationSplitView`.
///
/// Deliberate (design decision, 2026-07-27): the split-view containers bring a
/// sidebar-collapse toolbar button that can only be removed with private-API
/// hacks, and their rows surface to accessibility as table cells. Plain buttons
/// keep the window chrome under our control and give the AX drills a stable
/// `AXButton` + identifier to press.
struct SettingsSidebarView: View {
    @Binding var selection: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsTab.primarySidebarItems, id: \.self) { tab in
                SettingsSidebarRow(tab: tab, isSelected: selection == tab) {
                    selection = tab
                }
            }

            Spacer(minLength: 12)

            ForEach(SettingsTab.metaSidebarItems, id: \.self) { tab in
                SettingsSidebarRow(tab: tab, isSelected: selection == tab) {
                    selection = tab
                }
            }

            SettingsSidebarVersionFooter()
        }
        .padding(.horizontal, SettingsSidebarMetrics.horizontalInset)
        .padding(.top, SettingsSidebarMetrics.topInset)
        .padding(.bottom, 12)
        .frame(width: SettingsSidebarMetrics.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsSidebarBackground())
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
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
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .help(tab.subtitle)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(tab.accessibilityIdentifier)
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
