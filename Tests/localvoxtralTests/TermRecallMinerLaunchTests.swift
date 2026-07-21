import Foundation
import XCTest

@testable import localvoxtral

/// Marker-gated launcher for the PRIVATE term-recall ASR-corruption miner.
/// The SSH build gate permits `swift test` but not arbitrary executables, so
/// `scripts/remote-build.sh mine-term-recall [N]` enables this test and
/// relays the miner's sentinel report — the same pattern as
/// `SpeechdStreamingBenchTests`. The miner's inputs and outputs stay under
/// the gitignored `EvalRecordings/term-recall/`; the relayed report is
/// transcript-derived and must never be quoted into public PRs or issues
/// (see `EvalCorpus/term-recall/README.md`).
final class TermRecallMinerLaunchTests: XCTestCase {
    private static let markerFileName = ".term-recall-mine-enable.json"
    private static let reportBegin = "=== TERM-RECALL-MINING-REPORT-BEGIN ==="
    private static let reportEnd = "=== TERM-RECALL-MINING-REPORT-END ==="

    private struct MarkerConfig: Decodable {
        let limit: Int?
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testMinerRunsAndEmitsSentinelReport() throws {
        let markerURL = repoRoot.appendingPathComponent(Self.markerFileName)
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            throw XCTSkip(
                "Term-recall miner disabled; run ./scripts/remote-build.sh mine-term-recall"
            )
        }
        let config = try JSONDecoder().decode(
            MarkerConfig.self,
            from: Data(contentsOf: markerURL)
        )

        let casesURL = repoRoot.appendingPathComponent(
            "EvalRecordings/term-recall/cases.json"
        )
        guard FileManager.default.fileExists(atPath: casesURL.path) else {
            XCTFail(
                "cases.json missing at \(casesURL.path); harvest on the Linux box "
                    + "and sync it (and ONLY it) into the tree first"
            )
            return
        }
        let script = repoRoot.appendingPathComponent("scripts/mine-term-recall-asr.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        var arguments = [script.path]
        if let limit = config.limit {
            arguments.append(contentsOf: ["--limit", "\(limit)"])
        }
        process.arguments = arguments
        process.currentDirectoryURL = repoRoot
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutLog = MinerLineLog()
        let stderrLog = MinerLineLog()
        let stdoutReader = PipeLineReader(
            fileHandle: stdout.fileHandleForReading,
            onLine: stdoutLog.append
        )
        let stderrReader = PipeLineReader(
            fileHandle: stderr.fileHandleForReading,
            onLine: stderrLog.append
        )

        try process.run()
        stdoutReader.start()
        stderrReader.start()
        process.waitUntilExit()
        stdoutReader.waitUntilFinished()
        stderrReader.waitUntilFinished()

        let lines = stdoutLog.snapshot()
        for line in lines { print(line) }
        for line in stderrLog.snapshot() { print("term-recall miner stderr: \(line)") }

        XCTAssertEqual(
            process.terminationStatus,
            0,
            "term-recall miner failed with status \(process.terminationStatus)"
        )
        XCTAssertTrue(
            lines.contains(Self.reportBegin),
            "missing report sentinel; the miner did not reach its report"
        )
        XCTAssertTrue(
            lines.contains(Self.reportEnd),
            "report sentinel never closed; the miner died mid-report"
        )
    }
}

private final class MinerLineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
