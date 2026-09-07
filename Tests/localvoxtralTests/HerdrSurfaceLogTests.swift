import Foundation
import XCTest

#if canImport(Darwin)

final class HerdrSurfaceLogTests: XCTestCase {
    func testLastFrameAndSidebarWidthComeFromRenderedCursorPositions() throws {
        let path = NSTemporaryDirectory() + "lvx-herdr-frame-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let raw = "\u{1B}[2J\u{1B}[1;1Hleft\u{1B}[1;6H│right"
            + "\u{1B}[2;1Hagent\u{1B}[2;6H│pane"
            + "\u{1B}[1;1Hdone"
        try Data(raw.utf8).write(to: URL(fileURLWithPath: path))

        let surface = HerdrSurfaceLog(path: path)
        XCTAssertEqual(surface.observedSidebarWidth(rows: 2, columns: 12), 6)
        XCTAssertEqual(surface.lastRenderedFrame(rows: 2, columns: 12), "done │right\nagent│pane")
    }
}

#endif
