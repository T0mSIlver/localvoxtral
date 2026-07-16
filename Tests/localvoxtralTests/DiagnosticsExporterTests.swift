import Foundation
import XCTest
@testable import localvoxtral

@MainActor
final class DiagnosticsExporterTests: XCTestCase {
    private var defaultsSuiteName = ""
    private var defaults: UserDefaults!
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuiteName = "localvoxtral.DiagnosticsExporterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsExporterTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        defaults?.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = ""
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults, environment: [:])
    }

    /// A store in external-URL mode with a user-entered endpoint, so the
    /// exporter surfaces the user endpoint (the path where a stray API key or
    /// embedded credential could otherwise leak).
    private func makeExternalStore(endpoint: String = "ws://127.0.0.1:8000/v1/realtime") -> SettingsStore {
        let store = makeStore()
        store.dictationBackendMode = .externalURL
        store.polishingBackendMode = .externalURL
        store.realtimeProvider = .realtimeAPI
        store.realtimeAPIEndpointURL = endpoint
        return store
    }

    private func makeSnapshot(
        settings: SettingsStore,
        speechdStatus: ManagedBackendStatus = .stopped,
        polishdStatus: ManagedBackendStatus = .stopped,
        speechdRecentOutput: [String] = [],
        polishdRecentOutput: [String] = []
    ) -> DiagnosticsSnapshot {
        DiagnosticsExporter.makeSnapshot(
            settings: settings,
            speechdStatus: speechdStatus,
            polishdStatus: polishdStatus,
            speechdRecentOutput: speechdRecentOutput,
            polishdRecentOutput: polishdRecentOutput
        )
    }

    // MARK: - Section presence

    func testReportContainsExpectedSections() {
        let store = makeExternalStore()
        let snapshot = makeSnapshot(settings: store)
        let report = DiagnosticsExporter.makeReport(snapshot: snapshot, now: Date())

        XCTAssertTrue(report.contains("localvoxtral diagnostics"))
        XCTAssertTrue(report.contains("== App =="))
        XCTAssertTrue(report.contains("== OS =="))
        XCTAssertTrue(report.contains("== Backend configuration =="))
        XCTAssertTrue(report.contains("== Managed backend status =="))
        XCTAssertTrue(report.contains("== Managed backend recent output =="))
        XCTAssertTrue(report.contains("dictation mode: External URL"))
        XCTAssertTrue(report.contains("polishing mode: External URL"))
        XCTAssertTrue(report.contains("realtime endpoint: ws://127.0.0.1:8000/v1/realtime"))
        XCTAssertTrue(report.contains("realtime API key: not set"))
        XCTAssertTrue(report.contains("LLM polishing: <disabled>"))
        XCTAssertTrue(report.contains("dictation engine (localvoxtral-speechd): stopped"))
        XCTAssertTrue(report.contains("polishing engine (localvoxtral-polishd): stopped"))
    }

    func testReportIncludesSupervisorOutputWhenPresent() {
        let store = makeExternalStore()
        let snapshot = makeSnapshot(
            settings: store,
            speechdRecentOutput: [
                "[localvoxtral-speechd stdout] INFO started",
                "[localvoxtral-speechd stderr] listening",
            ],
            polishdRecentOutput: ["[localvoxtral-polishd stdout] ready"]
        )
        let report = DiagnosticsExporter.makeReport(snapshot: snapshot, now: Date())

        XCTAssertTrue(report.contains("-- localvoxtral-speechd --"))
        XCTAssertTrue(report.contains("[localvoxtral-speechd stdout] INFO started"))
        XCTAssertTrue(report.contains("[localvoxtral-speechd stderr] listening"))
        XCTAssertTrue(report.contains("-- localvoxtral-polishd --"))
        XCTAssertTrue(report.contains("[localvoxtral-polishd stdout] ready"))
    }

    // MARK: - API key redaction (the core privacy property)

    func testReportExcludesRealtimeAPIKeyValueWhenSet() {
        let store = makeExternalStore()
        store.apiKey = "sk-test-DO-NOT-LEAK-REALTIME-7c9f"

        let snapshot = makeSnapshot(settings: store)
        let report = DiagnosticsExporter.makeReport(snapshot: snapshot, now: Date())

        // The key value must never appear, but its presence is reported as a boolean.
        XCTAssertFalse(report.contains("sk-test-DO-NOT-LEAK-REALTIME-7c9f"))
        XCTAssertTrue(report.contains("realtime API key: set"))
    }

    func testReportExcludesPolishingAPIKeyValueWhenSet() {
        let store = makeExternalStore()
        store.llmPolishingEnabled = true
        store.llmPolishingEndpointURL = "http://127.0.0.1:8080/v1/chat/completions"
        store.llmPolishingAPIKey = "polish-DO-NOT-LEAK-9a4b"

        let snapshot = makeSnapshot(settings: store)
        let report = DiagnosticsExporter.makeReport(snapshot: snapshot, now: Date())

        XCTAssertFalse(report.contains("polish-DO-NOT-LEAK-9a4b"))
        XCTAssertTrue(report.contains("LLM polishing API key: set"))
    }

    func testReportExcludesEmbeddedEndpointCredentials() {
        let store = makeExternalStore(
            endpoint: "ws://alice:hunter2@127.0.0.1:8000/v1/realtime?token=sekret-fragment#frag"
        )

        let snapshot = makeSnapshot(settings: store)
        let report = DiagnosticsExporter.makeReport(snapshot: snapshot, now: Date())

        XCTAssertFalse(report.contains("alice"))
        XCTAssertFalse(report.contains("hunter2"))
        XCTAssertFalse(report.contains("sekret"))
        XCTAssertFalse(report.contains("frag"))
        XCTAssertTrue(report.contains("127.0.0.1:8000"))
    }

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

    // MARK: - File writing: injected directory + injected timestamp

    func testWriteReportUsesInjectedDirectoryAndTimestamp() throws {
        let store = makeExternalStore()
        let snapshot = makeSnapshot(settings: store)

        // Fixed injected clock — UTC 2025-07-04T13:02:05 — so the filename is
        // fully determined by the seam, not wall-clock.
        var components = DateComponents()
        components.year = 2025
        components.month = 7
        components.day = 4
        components.hour = 13
        components.minute = 2
        components.second = 5
        components.timeZone = TimeZone(identifier: "UTC")
        let now = Calendar(identifier: .gregorian).date(from: components)!

        let writtenURL = try DiagnosticsExporter.writeReport(
            snapshot: snapshot,
            to: tempDirectory,
            now: now
        )

        let expectedFilename = "localvoxtral-diagnostics-2025-07-04T13-02-05.txt"
        XCTAssertEqual(writtenURL.lastPathComponent, expectedFilename)
        XCTAssertEqual(writtenURL.deletingLastPathComponent(), tempDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: writtenURL.path))

        let content = try String(contentsOf: writtenURL, encoding: .utf8)
        XCTAssertTrue(content.contains("localvoxtral diagnostics"))
        XCTAssertTrue(content.contains("== Backend configuration =="))
        // Must be written under the injected temp dir, never the real Desktop.
        XCTAssertFalse(writtenURL.path.contains("Desktop"))
    }

    func testWriteReportContentMatchesMakeReport() throws {
        let store = makeExternalStore()
        let snapshot = makeSnapshot(
            settings: store,
            speechdRecentOutput: ["[localvoxtral-speechd stdout] up"]
        )
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let writtenURL = try DiagnosticsExporter.writeReport(
            snapshot: snapshot,
            to: tempDirectory,
            now: now
        )
        let onDisk = try String(contentsOf: writtenURL, encoding: .utf8)
        let direct = DiagnosticsExporter.makeReport(snapshot: snapshot, now: now)
        XCTAssertEqual(onDisk, direct)
    }
}
