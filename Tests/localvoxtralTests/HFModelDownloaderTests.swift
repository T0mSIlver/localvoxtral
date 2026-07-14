import CryptoKit
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

    /// Regression, 2026-07-14: the downloader tracked the repo's main ref, so
    /// an upstream commit (vision tower registered in the weight index)
    /// silently changed what every install fetched. The pin must reach BOTH
    /// snapshot_download calls — the dry run that sizes the progress bar and
    /// the real fetch — or the bar and the weights describe different commits.
    func testEmbeddedScriptPassesPinnedRevisionToSnapshotDownload() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localvoxtral-revision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let uvURL = try await Self.resolveUVForRealTqdmTest(
            fallbackRoot: tempDirectory.appendingPathComponent("managed-uv", isDirectory: true)
        )
        let scriptURL = tempDirectory.appendingPathComponent("hf_model_download.py")
        try HFModelDownloader.pythonDownloaderScript.write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )
        let driverURL = tempDirectory.appendingPathComponent("revision_driver.py")
        try Self.snapshotDownloadStubDriver.write(to: driverURL, atomically: true, encoding: .utf8)

        // Runs the REAL script (argparse + both snapshot_download calls) with
        // huggingface_hub stubbed, so the assertion is on the shipped source.
        let pinned = try await Self.runScript(
            uv: uvURL,
            driver: driverURL,
            script: scriptURL,
            arguments: ["org/model", "--include", "*.json", "--revision", "abc123"]
        )
        XCTAssertEqual(pinned, ["abc123", "abc123"])

        // No pin (custom repo id) still means "track main": revision=None.
        let unpinned = try await Self.runScript(
            uv: uvURL,
            driver: driverURL,
            script: scriptURL,
            arguments: ["org/model", "--include", "*.json"]
        )
        XCTAssertEqual(unpinned, [nil, nil])
    }

    /// Runs the embedded downloader script under the stub driver and returns
    /// the `revision=` each snapshot_download call received (dry run, fetch).
    private static func runScript(
        uv: URL,
        driver: URL,
        script: URL,
        arguments: [String]
    ) async throws -> [String?] {
        let result = try runProcess(
            executableURL: uv,
            arguments: ["run", "--with", "tqdm<5", "python3", driver.path, script.path] + arguments,
            environment: ["LOCALVOXTRAL_HF_EMIT_INTERVAL": "0"]
        )
        XCTAssertEqual(
            result.exitCode,
            0,
            "stub driver failed\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
        )
        let line = try XCTUnwrap(
            result.stdout
                .split(separator: "\n")
                .first { $0.contains("\"revisions\"") },
            "driver emitted no revisions line\nstdout:\n\(result.stdout)"
        )
        struct Recorded: Decodable { let revisions: [String?] }
        return try JSONDecoder().decode(Recorded.self, from: Data(line.utf8)).revisions
    }

    private static let snapshotDownloadStubDriver = #"""
import json
import sys
import types

script_path = sys.argv[1]
sys.argv = [script_path] + sys.argv[2:]

revisions = []


def snapshot_download(repo, allow_patterns=None, revision=None, dry_run=False, tqdm_class=None):
    revisions.append(revision)
    if dry_run:
        return []
    return "/tmp/snapshot"


stub = types.ModuleType("huggingface_hub")
stub.snapshot_download = snapshot_download
sys.modules["huggingface_hub"] = stub

with open(script_path, "r", encoding="utf-8") as handle:
    source = handle.read()

exec(compile(source, script_path, "exec"), {"__name__": "__main__"})

# Written last: a script that raised never reaches this line.
sys.stdout.write(json.dumps({"revisions": revisions}) + "\n")
sys.stdout.flush()
"""#

    func testEmbeddedJSONTqdmReportsCumulativeByteProgressWithRealTqdm() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("localvoxtral-json-tqdm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let uvURL = try await Self.resolveUVForRealTqdmTest(
            fallbackRoot: tempDirectory.appendingPathComponent("managed-uv", isDirectory: true)
        )

        let scriptURL = tempDirectory.appendingPathComponent("hf_model_download.py")
        try HFModelDownloader.pythonDownloaderScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let driverURL = tempDirectory.appendingPathComponent("json_tqdm_driver.py")
        try Self.jsonTqdmDriver.write(to: driverURL, atomically: true, encoding: .utf8)

        let result = try Self.runProcess(
            executableURL: uvURL,
            arguments: [
                "run",
                "--with",
                "tqdm<5",
                "python3",
                driverURL.path,
                scriptURL.path,
            ],
            environment: ["LOCALVOXTRAL_HF_EMIT_INTERVAL": "0"]
        )

        XCTAssertEqual(
            result.exitCode,
            0,
            "real-tqdm driver failed\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
        )

        let progressEvents = result.stdout
            .split(separator: "\n")
            .compactMap { ModelDownloadJSONParser.parse(String($0)) }

        XCTAssertEqual(
            progressEvents,
            [
                .progress(repo: "org/model", downloadedBytes: 7, totalBytes: nil),
                .progress(repo: "org/model", downloadedBytes: 20, totalBytes: nil),
                .progress(repo: "org/model", downloadedBytes: 25, totalBytes: nil),
                // Restarted file: the new bar REPLACES the old position…
                .progress(repo: "org/model", downloadedBytes: 55, totalBytes: nil),
                .progress(repo: "org/model", downloadedBytes: 35, totalBytes: nil),
                // …and a resumed bar's initial= bytes count toward the sum.
                .progress(repo: "org/model", downloadedBytes: 105, totalBytes: nil),
            ]
        )
        XCTAssertFalse(result.stderr.contains("Fetching"), "tqdm rendered to stderr: \(result.stderr)")
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

    private static let jsonTqdmDriver = #"""
import json
import os
import sys
import types

from tqdm.auto import tqdm

script_path = sys.argv[1]
with open(script_path, "r", encoding="utf-8") as handle:
    source = handle.read()

start = source.index("def emit(payload):")
end = source.index("\ndef resolve_total", start)
namespace = {
    "json": json,
    "os": os,
    "sys": sys,
    "threading": __import__("threading"),
    "time": __import__("time"),
    "tqdm": tqdm,
    "ARGS": types.SimpleNamespace(repo="org/model"),
}
exec(compile(source[start:end], script_path, "exec"), namespace)

events = []
namespace["emit"] = events.append

byte_bar = namespace["JSONTqdm"](total=100, unit="B")
byte_bar.update(7)
byte_bar.update(13)
byte_bar.close()

count_bar = namespace["JSONTqdm"](total=2, unit="files")
count_bar.update(1)
count_bar.update(1)
count_bar.close()

# A second byte bar (snapshot_download runs one per file) must continue the
# shared aggregate, not restart from its own n.
second_byte_bar = namespace["JSONTqdm"](total=50, unit="B")
second_byte_bar.update(5)
second_byte_bar.close()

# A restarted file (same desc, hf_hub names bars by filename) must REPLACE its
# old position, not add to it — delta counting inflated the aggregate past the
# total in the field ("6 GB / 3.3 GB") whenever a partial blob was invalidated.
restart_first = namespace["JSONTqdm"](total=40, unit="B", desc="model.safetensors")
restart_first.update(30)
restart_first.close()
restart_second = namespace["JSONTqdm"](total=40, unit="B", desc="model.safetensors")
restart_second.update(10)
restart_second.close()

# A resumed file's bar starts at initial=resume_size; the already-on-disk bytes
# count toward the aggregate as soon as the bar reports real progress.
resumed = namespace["JSONTqdm"](total=100, unit="B", initial=60, desc="weights.safetensors")
resumed.update(10)
resumed.close()

expected_downloaded = [7, 20, 25, 55, 35, 105]
actual_downloaded = [event["downloaded"] for event in events]
if actual_downloaded != expected_downloaded:
    raise AssertionError(f"downloaded counts {actual_downloaded} != {expected_downloaded}")
if any(event["total"] is not None for event in events):
    raise AssertionError("progress events must not carry per-bar totals")

for event in events:
    print(json.dumps(event, separators=(",", ":")), flush=True)
"""#

    private static func findUVBinary() -> URL? {
        let fileManager = FileManager.default
        let knownURLs = [
            BackendInstallLayout().managedUVBinary,
            URL(fileURLWithPath: "/opt/homebrew/bin/uv"),
            URL(fileURLWithPath: "/usr/local/bin/uv"),
        ]
        for url in knownURLs where fileManager.isExecutableFile(atPath: url.path) {
            return url
        }

        for directory in ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? [] {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent("uv").path
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func resolveUVForRealTqdmTest(fallbackRoot: URL) async throws -> URL {
        if let uvURL = findUVBinary() {
            return uvURL
        }
        let fallbackLayout = BackendInstallLayout(root: fallbackRoot)
        try await provisionManagedUVForRealTqdmTest(layout: fallbackLayout)
        guard FileManager.default.isExecutableFile(atPath: fallbackLayout.managedUVBinary.path) else {
            XCTFail("uv not found after provisioning managed uv at \(fallbackLayout.managedUVBinary.path)")
            throw BackendInstallError.uvNotFound
        }
        return fallbackLayout.managedUVBinary
    }

    private static func provisionManagedUVForRealTqdmTest(layout: BackendInstallLayout) async throws {
        let distribution = UVDistribution.pinned
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: layout.uvBinaryDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: layout.downloads, withIntermediateDirectories: true)

        let tarballURL = layout.downloads.appendingPathComponent(distribution.tarballURL.lastPathComponent)
        let (data, _) = try await URLSession.shared.data(from: distribution.tarballURL)
        let actualSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actualSHA256, distribution.tarballSHA256)
        try data.write(to: tarballURL, options: .atomic)

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("localvoxtral-test-uv-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let extraction = try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: [
                "-xzf",
                tarballURL.path,
                "-C",
                temporaryDirectory.path,
                distribution.archiveBinaryPath,
            ],
            environment: [:]
        )
        XCTAssertEqual(extraction.exitCode, 0, "uv extraction failed: \(extraction.stderr)")

        let extractedUV = temporaryDirectory.appendingPathComponent(distribution.archiveBinaryPath)
        if fileManager.fileExists(atPath: layout.managedUVBinary.path) {
            try fileManager.removeItem(at: layout.managedUVBinary)
        }
        try fileManager.copyItem(at: extractedUV, to: layout.managedUVBinary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.managedUVBinary.path)
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }
}
