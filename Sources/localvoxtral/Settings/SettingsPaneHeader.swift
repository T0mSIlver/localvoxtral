import SwiftUI

/// Title + one-line purpose for the selected pane, above its scrolling content.
///
/// The subtitle exists because the sidebar row labels are short nouns: "Where
/// speech recognition and polishing run" is the sentence that used to be missing
/// entirely from the tabbed layout.
struct SettingsPaneHeader: View {
    let tab: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tab.title)
                .font(.system(size: 20, weight: .semibold))

            Text(tab.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        // Matches the sidebar's inset: the window draws its content full-size
        // under a transparent titlebar, so the header needs the same clearance.
        .padding(.top, SettingsSidebarMetrics.topInset)
        .padding(.bottom, 12)
    }
}
