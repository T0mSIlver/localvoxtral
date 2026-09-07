import SwiftUI

/// The selected pane's title, above its scrolling content. Title only: the
/// per-pane subtitles were narration and were removed (owner review,
/// 2026-09-07) — what a pane does is the docs' job, and every line here
/// pushed the first group down.
struct SettingsPaneHeader: View {
    let tab: SettingsTab

    var body: some View {
        Text(tab.title)
            .font(.system(size: 20, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            // Matches the sidebar's inset: the window draws its content full-size
            // under a transparent titlebar, so the header needs the same clearance.
            .padding(.top, SettingsSidebarMetrics.topInset)
            .padding(.bottom, 6)
    }
}
