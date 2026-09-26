import AppKit

extension CmuxSocketClient {
    /// LaunchServices' bundle id for a running pid, which the peer check
    /// compares against cmux's. In the app because the core has no AppKit.
    static func runningBundleID(ofPID pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
