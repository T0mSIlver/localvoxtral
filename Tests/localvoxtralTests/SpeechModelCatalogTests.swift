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

    /// The build host serves one test service per row of this list, and eval-e2e
    /// scores whichever one it names. A catalog model without a row cannot be
    /// scored there, and a stale row serves weights the app no longer ships.
    func testBuildHostServesEveryCatalogModelAtItsPin() throws {
        let list = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/mac/test-speech-models.tsv")
        let rows = try String(contentsOf: list, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.allSatisfy(\.isWhitespace) }
            .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }

        XCTAssertTrue(rows.allSatisfy { $0.count == 4 }, "\(rows)")
        XCTAssertEqual(
            Set(rows.map { "\($0[2])@\($0[3])" }),
            Set(SpeechModelCatalog.options.map { "\($0.repoID)@\($0.revision)" })
        )
        XCTAssertEqual(Set(rows.map { $0[0] }).count, rows.count, "names must be unique")
        XCTAssertEqual(Set(rows.map { $0[1] }).count, rows.count, "ports must be unique")
        XCTAssertFalse(rows.contains { $0[1] == "8080" }, "8080 is the polishd test service")
        // CI and older build gates reach Voxtral on 8000 without reading the list.
        XCTAssertEqual(rows.first { $0[0] == "voxtral" }?[1], "8000")
    }
}
