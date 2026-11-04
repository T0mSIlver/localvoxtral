import Foundation

/// The folder the app keeps its own data in: History, recordings, diagnostic
/// records, learned terms, the usage ledger, configs and the
/// Claude session cache. `~/Library/Application Support/localvoxtral`, or
/// `LOCALVOXTRAL_DATA_HOME` when set.
///
/// The override is for launches on the owner's Mac that are not the owner:
/// the e2e dictation, the UI smoke and the demo recording run as the owner
/// and must not open the owner's data (#985).
/// Sockets, plugin links and downloaded backends stay put: other programs
/// find them by their fixed path. The widget snapshot moves, so the owner's
/// widget keeps showing the owner's app (`WidgetShared.writerFileURL`).
///
/// A test launch that names no folder gets a new temporary one instead of the
/// owner's: the e2e harness bundle, or any build dictating from a WAV
/// (`LOCALVOXTRAL_DOGFOOD_AUDIO_FILE`). A harness opened by hand, the way
/// `docs/test-harness.md` shows, once wrote its test dictations into the
/// owner's History.
package enum LocalvoxtralDataDirectory {
    package static let environmentKey = "LOCALVOXTRAL_DATA_HOME"
    /// The e2e harness's bundle id (`scripts/e2e-dictation.sh`, #1202).
    package static let harnessBundleIdentifier = "com.localvoxtral.e2e-harness"

    package static func url(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> URL {
        if let home = override(environment) {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        if isTestLaunch(environment: environment, bundleIdentifier: bundleIdentifier) {
            return testLaunchFolder
        }
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("localvoxtral", isDirectory: true)
    }

    /// True when the data folder is not the owner's: an override, or a test
    /// launch's temporary folder.
    package static func isOverridden(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        override(environment) != nil
            || isTestLaunch(environment: environment, bundleIdentifier: bundleIdentifier)
    }

    private static func override(_ environment: [String: String]) -> String? {
        guard let home = environment[environmentKey], home.hasPrefix("/") else { return nil }
        return home
    }

    private static func isTestLaunch(environment: [String: String], bundleIdentifier: String?) -> Bool {
        if bundleIdentifier == harnessBundleIdentifier { return true }
        // Only these builds can dictate from a file; a release never reads the variable.
        #if DEBUG || LOCALVOXTRAL_E2E_HARNESS
        if !(environment[DogfoodAudioFileSource.environmentKey] ?? "").isEmpty { return true }
        #endif
        return false
    }

    /// One folder per process, so every store of one launch shares it.
    private static let testLaunchFolder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "localvoxtral-test-launch-data.\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
        Log.dictation.notice(
            "Test launch without \(environmentKey, privacy: .public): data goes to \(folder.path, privacy: .public), not the owner's folder"
        )
        return folder
    }()
}
