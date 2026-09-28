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
}
