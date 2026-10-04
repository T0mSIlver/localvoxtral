import Foundation
import XCTest
@testable import localvoxtral

final class DiagnosticsExporterTests: XCTestCase {
    func testSanitizedEndpointDescriptionStripsCredentials() {
        let url = URL(string: "wss://user:pass@example.com:9000/path?token=x#section")!
        XCTAssertEqual(
            DiagnosticsExporter.sanitizedEndpointDescription(from: url),
            "wss://example.com:9000/path"
        )
    }

    func testSanitizedEndpointDescriptionHandlesNil() {
        XCTAssertEqual(DiagnosticsExporter.sanitizedEndpointDescription(from: nil), "<invalid endpoint>")
    }

    // MARK: - Status rendering

    func testDescribeStatusVariants() {
        XCTAssertEqual(DiagnosticsExporter.describe(.ready), "ready")
        XCTAssertEqual(DiagnosticsExporter.describe(.starting), "starting")
        XCTAssertEqual(DiagnosticsExporter.describe(.stopped), "stopped")
        XCTAssertEqual(DiagnosticsExporter.describe(.failed(summary: "boom", detail: nil)), "failed: boom")
        XCTAssertEqual(
            DiagnosticsExporter.describe(.failed(summary: "boom", detail: "stderr: trace")),
            "failed: boom — stderr: trace"
        )
        XCTAssertTrue(
            DiagnosticsExporter
                .describe(.preparingModel(progress: ModelDownloadProgress(downloadedBytes: 50, totalBytes: 100)))
                .contains("50%")
        )
    }
}
