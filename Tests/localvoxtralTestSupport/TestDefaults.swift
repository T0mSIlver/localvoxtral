import Foundation
import XCTest

/// A `UserDefaults` suite for one test, kept out of `~/Library/Preferences`.
///
/// A suite named like `localvoxtral.SomeTests.<UUID>` is a plist in
/// `~/Library/Preferences`. `removePersistentDomain(forName:)` empties that
/// plist but leaves the file, and cfprefsd writes it back after a delete, so
/// every run left one file per test: 310k of them on the owner's Mac. A suite
/// named by an absolute path is stored in that file instead, so each suite
/// gets a folder of its own under the temporary directory, deleted at teardown.
///
/// Every test suite in `Tests/` comes from here; `scripts/ci/test-defaults-suites.sh`
/// fails on any other `UserDefaults(suiteName:)`.
package struct TestDefaults: @unchecked Sendable {
    package let defaults: UserDefaults
    /// The suite's name: an absolute path, without the `.plist`. Open a second
    /// `UserDefaults(suiteName:)` on it to read what another instance wrote.
    package let suiteName: String
    private let directory: URL

    package init(label: String = "defaults") {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localvoxtral-test-defaults.\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = directory.appendingPathComponent(label).path
        defaults = UserDefaults(suiteName: suiteName)!
    }

    /// A second instance over the same suite, the way the app sees it after a
    /// relaunch.
    package func reopened() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    /// Empties the suite and deletes its folder.
    package func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

extension XCTestCase {
    /// An empty suite for this test, removed at teardown.
    package func makeTestDefaults() -> UserDefaults {
        makeTestDefaultsSuite().defaults
    }

    /// The suite with its name, for a test that reopens it or needs the name.
    package func makeTestDefaultsSuite(label: String = "defaults") -> TestDefaults {
        let suite = TestDefaults(label: label)
        addTeardownBlock { suite.remove() }
        return suite
    }
}
