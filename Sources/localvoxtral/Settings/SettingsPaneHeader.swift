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
            .frame(maxWidth: .infinity, minHeight: SettingsSidebarMetrics.rowHeight, alignment: .leading)
            .padding(.horizontal, 18)
            // The sidebar's inset and row height: the title sits level with
            // the first sidebar row. No divider below it — the white column
            // and the unbordered cards carry the separation.
            .padding(.top, SettingsSidebarMetrics.topInset)
    }
}
