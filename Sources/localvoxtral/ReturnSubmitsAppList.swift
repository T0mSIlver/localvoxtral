import Foundation

/// Apps where Return submits the prompt: the spoken send trigger (#318) may
/// press Return only in one of these.
///
/// Every terminal (the built-in list and Settings → Terminals), plus the
/// non-terminal apps below. A separate list from `TerminalTargetDetector`'s,
/// because being a terminal changes far more than the send trigger (newline
/// collapsing, the TUI trailing-space policy, the polish profile), and Claude
/// Desktop's prompt is a text field that must keep its newlines (#660).
@MainActor
enum ReturnSubmitsAppList {
    /// Non-terminal apps whose prompt box sends on Return.
    private static let promptAppBundleIDs: Set<String> = [
        ClaudeDesktopAllowlist.bundleID,
    ]

    /// By bundle ID only: the AX probe reads the element focused now, which
    /// need not belong to the app the Return would go to.
    static func contains(_ bundleID: String?, userTerminalBundleIDs: Set<String>) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return TerminalTargetDetector.isTerminalLikeBundleID(bundleID)
            || userTerminalBundleIDs.contains(bundleID)
            || promptAppBundleIDs.contains(bundleID)
    }
}
