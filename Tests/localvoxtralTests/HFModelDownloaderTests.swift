import Foundation
import XCTest
@testable import localvoxtral

final class HFModelDownloaderTests: XCTestCase {
    func testModelDownloadJSONParserParsesValidProgressLines() {
        XCTAssertEqual(
            ModelDownloadJSONParser.parse(#"{"event":"total","repo":"org/model","total":123}"#),
            .total(repo: "org/model", totalBytes: 123)
        )
        XCTAssertEqual(
            ModelDownloadJSONParser.parse(#"{"event":"progress","repo":"org/model","downloaded":12,"total":123}"#),
            .progress(repo: "org/model", downloadedBytes: 12, totalBytes: 123)
        )
        XCTAssertEqual(
            ModelDownloadJSONParser.parse(#"{"event":"done","repo":"org/model"}"#),
            .done(repo: "org/model")
        )
    }

    func testModelDownloadJSONParserIgnoresGarbageLines() {
        XCTAssertNil(ModelDownloadJSONParser.parse("not json"))
        XCTAssertNil(ModelDownloadJSONParser.parse(#"{"event":"progress","repo":"org/model"}"#))
        XCTAssertNil(ModelDownloadJSONParser.parse(#"{"event":"unknown","repo":"org/model"}"#))
    }

    func testModelDownloadJSONParserParsesErrorEvent() {
        XCTAssertEqual(
            ModelDownloadJSONParser.parse(#"{"event":"error","message":"token rejected"}"#),
            .error(message: "token rejected")
        )
    }

    @MainActor
    func testModelDownloadProcessStreamsJSONProgressFromShell() async throws {
        var progressEvents: [ModelDownloadProgress] = []

        let result = try await ModelDownloadProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                printf '%s\n' \
                  '{"event":"total","repo":"org/model","total":100}' \
                  'ignore me' \
                  '{"event":"progress","repo":"org/model","downloaded":25,"total":100}' \
                  '{"event":"done","repo":"org/model"}'
                """,
            ],
            environment: [:],
            livenessTimeoutSeconds: 120
        ) { progress in
            progressEvents.append(progress)
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(
            progressEvents,
            [
                ModelDownloadProgress(downloadedBytes: 0, totalBytes: 100),
                ModelDownloadProgress(downloadedBytes: 25, totalBytes: 100),
                ModelDownloadProgress(downloadedBytes: 100, totalBytes: 100),
            ]
        )
    }

    @MainActor
    func testModelDownloadProcessTurnsErrorEventIntoDownloadError() async throws {
        do {
            _ = try await ModelDownloadProcess.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    """
                    printf '%s\n' '{"event":"error","message":"repo unavailable"}'
                    printf '%s\n' 'stderr detail marker' >&2
                    exit 1
                    """,
                ],
                environment: [:],
                livenessTimeoutSeconds: 120
            ) { _ in }
            XCTFail("expected downloader error")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error.localizedDescription, "repo unavailable")
            XCTAssertEqual(error.technicalDetails, "stderr detail marker")
        } catch {
            XCTFail("expected ModelDownloadError, got \(error)")
        }
    }
}
