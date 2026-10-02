import Foundation

/// The System Settings pane that holds the Accessibility grant. macOS 27
/// renamed it "Device Control and Data Access"; macOS 15 and 26 call it
/// "Accessibility". Copy that sends the user there takes the name from here.
package struct AccessibilitySettingsPane: Sendable, Equatable {
    package let name: String

    package init(macOSMajorVersion: Int) {
        name = macOSMajorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
    }

    /// The pane of the macOS this process runs on.
    package static let current = AccessibilitySettingsPane(
        macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    )

    package var path: String { "System Settings > Privacy & Security > \(name)" }
}
