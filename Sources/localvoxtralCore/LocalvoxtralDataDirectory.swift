import Foundation

/// The folder the app keeps its own data in: History, recordings, diagnostic
/// records, learned terms, quick captures, the usage ledger, configs and the
/// Claude session cache. `~/Library/Application Support/localvoxtral`, or
/// `LOCALVOXTRAL_DATA_HOME` when set.
///
/// The override is for launches on the owner's Mac that are not the owner:
/// the e2e dictation, the UI smoke and the demo recording run as the owner,
/// with the owner's preferences, and must not open the owner's data (#985).
/// Sockets, plugin links, the widget folder and downloaded backends stay put:
/// other programs find them by their fixed path.
package enum LocalvoxtralDataDirectory {
    package static let environmentKey = "LOCALVOXTRAL_DATA_HOME"

    package static func url(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let home = override(environment) {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("localvoxtral", isDirectory: true)
    }

    package static func isOverridden(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        override(environment) != nil
    }

    private static func override(_ environment: [String: String]) -> String? {
        guard let home = environment[environmentKey], home.hasPrefix("/") else { return nil }
        return home
    }
}
