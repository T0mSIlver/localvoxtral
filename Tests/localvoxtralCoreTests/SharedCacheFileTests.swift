import Foundation
import XCTest
import localvoxtralTestSupport

final class SharedCacheFileTests: XCTestCase {
    /// Two processes miss the same cache entry, both make it, and both get
    /// to publish before either has: both succeed and the entry is whole
    /// (#1525).
    func testTwoIdenticalMissesBothPublish() async throws {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-shared-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cache) }
        let destination = cache.appendingPathComponent("entry.wav")
        let content = Data("the same synthesized audio".utf8)
        let ready = EventCount()

        let callers = (0..<2).map { _ in
            Task.detached {
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a miss")
                let made = FileManager.default.temporaryDirectory
                    .appendingPathComponent("lv-made-\(UUID().uuidString).wav")
                try content.write(to: made)
                ready.increment()
                await ready.waitFor(2)
                try SharedCacheFile.publish(made, at: destination)
            }
        }
        for caller in callers {
            try await caller.value
        }

        XCTAssertEqual(try Data(contentsOf: destination), content)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: cache.path), ["entry.wav"],
            "no staged file is left behind"
        )
    }
}
