import Foundation
import XCTest
@testable import localvoxtralCore

final class LocalvoxtralDataDirectoryTests: XCTestCase {
    func testTheOverrideNamesTheDataFolder() {
        let environment = [LocalvoxtralDataDirectory.environmentKey: "/tmp/lv-lane-data"]
        XCTAssertEqual(LocalvoxtralDataDirectory.url(environment: environment).path, "/tmp/lv-lane-data")
        XCTAssertTrue(LocalvoxtralDataDirectory.isOverridden(environment: environment))
    }

    /// A relative or empty value would resolve against whatever the working
    /// directory is; the app's own folder is the safer reading.
    func testARelativeOrEmptyOverrideIsIgnored() {
        for value in ["", "lane-data", "./data"] {
            let environment = [LocalvoxtralDataDirectory.environmentKey: value]
            XCTAssertFalse(LocalvoxtralDataDirectory.isOverridden(environment: environment), value)
            XCTAssertEqual(LocalvoxtralDataDirectory.url(environment: environment).lastPathComponent, "localvoxtral")
        }
    }

    /// A build dictating from a WAV is a test, whoever launched it. Opened by
    /// hand without a data folder, it wrote its dictations into the owner's
    /// History; it now gets a temporary folder of its own.
    func testADictationFromAFileNeverOpensTheOwnersFolder() {
        let environment = [DogfoodAudioFileSource.environmentKey: "/tmp/utterance.wav"]
        let folder = LocalvoxtralDataDirectory.url(environment: environment)
        XCTAssertNotEqual(folder.lastPathComponent, "localvoxtral")
        XCTAssertTrue(folder.path.hasPrefix(FileManager.default.temporaryDirectory.path), folder.path)
        XCTAssertTrue(LocalvoxtralDataDirectory.isOverridden(environment: environment))
        XCTAssertEqual(LocalvoxtralDataDirectory.url(environment: environment), folder)
    }

    func testTheHarnessBundleNeverOpensTheOwnersFolder() {
        let harness = LocalvoxtralDataDirectory.harnessBundleIdentifier
        let folder = LocalvoxtralDataDirectory.url(environment: [:], bundleIdentifier: harness)
        XCTAssertTrue(folder.path.hasPrefix(FileManager.default.temporaryDirectory.path), folder.path)
        XCTAssertTrue(LocalvoxtralDataDirectory.isOverridden(environment: [:], bundleIdentifier: harness))
        XCTAssertEqual(
            LocalvoxtralDataDirectory.url(environment: [:], bundleIdentifier: "com.localvoxtral.app").lastPathComponent,
            "localvoxtral"
        )
    }

    func testALanesFolderStillWinsForATestLaunch() {
        let environment = [
            LocalvoxtralDataDirectory.environmentKey: "/tmp/lv-lane-data",
            DogfoodAudioFileSource.environmentKey: "/tmp/utterance.wav",
        ]
        let folder = LocalvoxtralDataDirectory.url(
            environment: environment, bundleIdentifier: LocalvoxtralDataDirectory.harnessBundleIdentifier)
        XCTAssertEqual(folder.path, "/tmp/lv-lane-data")
    }
}

/// The widget reads the snapshot from the real home. A lane's app writes its
/// own under its data folder, so it never replaces what the owner's widget
/// shows (#1029).
final class WidgetSnapshotLocationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    func testTheAppWritesWhereTheWidgetReadsWithoutAnOverride() {
        for environment in [[:], [LocalvoxtralDataDirectory.environmentKey: "lane-data"]] {
            XCTAssertEqual(
                WidgetShared.writerFileURL(environment: environment, home: home),
                WidgetShared.fileURL(home: home)
            )
        }
    }

    func testALaneWritesUnderItsDataFolder() {
        let environment = [LocalvoxtralDataDirectory.environmentKey: "/tmp/lv-lane-data"]
        let written = WidgetShared.writerFileURL(environment: environment, home: home)
        XCTAssertEqual(written.path, "/tmp/lv-lane-data/widgets/snapshot.json")
        XCTAssertNotEqual(written, WidgetShared.fileURL(home: home))
    }
}
