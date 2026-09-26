import CoreServices
import Foundation

/// Whether macOS already lets this app send Apple events to another app,
/// found without asking the user (#717). A background check, such as the
/// needs-you cue's "is the user looking at this pane", must never be the
/// thing that raises the Automation consent sheet.
enum AutomationConsent {
    static func isGranted(bundleID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            // It can block while macOS looks the target up.
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: determine(bundleID: bundleID))
            }
        }
    }

    private static func determine(bundleID: String) -> Bool {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = bytes.withUnsafeBytes { buffer in
            AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &target)
        }
        guard created == noErr else { return false }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(
            &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false
        )
        return status == noErr
    }
}
