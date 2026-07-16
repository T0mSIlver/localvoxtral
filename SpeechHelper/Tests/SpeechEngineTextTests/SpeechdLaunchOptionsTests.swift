import Foundation
import XCTest

@testable import SpeechEngineText

final class SpeechdLaunchOptionsTests: XCTestCase {
    func testParsesPinnedModelRevisionAndSupervisorArguments() throws {
        let options = try SpeechdOptionParser.parse([
            "--model", "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit",
            "--model-revision", "0123456789abcdef0123456789abcdef01234567",
            "--port", "8471",
            "--parent-pid", "4321",
        ])

        XCTAssertEqual(options.modelID, "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit")
        XCTAssertEqual(options.modelRevision, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(options.port, 8471)
        XCTAssertEqual(options.parentPID, 4321)
    }

    func testPinnedRevisionLocatorNeverFallsBackToMain() throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appending(path: "speechd-hf-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let repoID = "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"
        let snapshots = cacheRoot
            .appending(path: "models--mlx-community--Voxtral-Mini-4B-Realtime-2602-4bit")
            .appending(path: "snapshots")
        let pinned = snapshots.appending(path: "pinned")
        let main = snapshots.appending(path: "moved-main")
        try FileManager.default.createDirectory(at: pinned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: pinned.appending(path: "config.json"))
        try Data("{}".utf8).write(to: main.appending(path: "config.json"))

        XCTAssertEqual(
            try SpeechHFCacheModelLocator.locate(
                repoID: repoID,
                revision: "pinned",
                cacheRoot: cacheRoot
            ).standardizedFileURL,
            pinned.standardizedFileURL
        )
        XCTAssertThrowsError(
            try SpeechHFCacheModelLocator.locate(
                repoID: repoID,
                revision: "absent-pin",
                cacheRoot: cacheRoot
            )
        )
    }
}
