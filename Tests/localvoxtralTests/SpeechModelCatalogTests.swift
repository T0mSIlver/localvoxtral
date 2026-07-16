import XCTest

@testable import localvoxtral

final class SpeechModelCatalogTests: XCTestCase {
    func testManagedCatalogUsesBundledSpeechdAndRetainsVoxmlxOnlyForRetirement() {
        XCTAssertEqual(BackendCatalog.speechd.displayName, "Dictation engine")
        XCTAssertEqual(BackendCatalog.speechd.installKind, .bundledExecutable)
        XCTAssertEqual(BackendCatalog.speechd.executableName, "localvoxtral-speechd")
        XCTAssertEqual(BackendCatalog.speechd.port, 8471)
        XCTAssertEqual(BackendCatalog.all.map(\.id), ["speechd", "polishd"])
        XCTAssertFalse(BackendCatalog.all.contains { $0.id == BackendCatalog.voxmlx.id })
    }

    func testSpeechModelCatalogPinsFullCommitSHA() {
        let option = SpeechModelCatalog.defaultOption
        XCTAssertEqual(option.repoID, "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit")
        XCTAssertEqual(option.revision.count, 40)
        XCTAssertTrue(option.revision.allSatisfy(\.isHexDigit))
    }
}
