import XCTest

@testable import localvoxtral

final class SpeechModelCatalogTests: XCTestCase {
    func testManagedCatalogContainsOnlyBundledHelpers() {
        XCTAssertEqual(BackendCatalog.speechd.displayName, "Dictation engine")
        XCTAssertEqual(BackendCatalog.speechd.executableName, "localvoxtral-speechd")
        XCTAssertEqual(BackendCatalog.speechd.port, 8471)
        XCTAssertEqual(BackendCatalog.all.map(\.id), ["speechd", "polishd"])
        XCTAssertEqual(BackendCatalog.polishd.executableName, "localvoxtral-polishd")
    }

    func testSpeechModelCatalogPinsFullCommitSHA() {
        let option = SpeechModelCatalog.defaultOption
        XCTAssertEqual(option.repoID, "T0mSIlver/Voxtral-Mini-4B-Realtime-2602-4bit-qhead")
        XCTAssertEqual(option.revision.count, 40)
        XCTAssertTrue(option.revision.allSatisfy(\.isHexDigit))
    }
}
