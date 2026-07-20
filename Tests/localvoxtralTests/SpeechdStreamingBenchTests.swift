import Foundation
import XCTest

@testable import localvoxtral

/// Marker-gated launcher for the packaged speech helper's Metal benchmark.
/// The SSH build gate permits `swift test` but not arbitrary executables, so
/// `scripts/remote-build.sh speechd-bench` enables this test and relays BENCH lines.
final class SpeechdStreamingBenchTests: XCTestCase {
    private static let markerFileName = ".speechd-bench-enable.json"
    private static let defaultHelperPath =
        "dist/localvoxtral.app/Contents/MacOS/localvoxtral-speechd"

    private struct MarkerConfig: Decodable {
        let helperPath: String?
        let seconds: Int
        let cadenceMilliseconds: Int
        let wavPath: String?
        let cacheLimitMB: Int?
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPackagedStreamingBenchmark() throws {
        let markerURL = repoRoot.appendingPathComponent(Self.markerFileName)
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            throw XCTSkip(
                "Speechd benchmark disabled; run ./scripts/remote-build.sh speechd-bench"
            )
        }
        let config = try JSONDecoder().decode(
            MarkerConfig.self,
            from: Data(contentsOf: markerURL)
        )
        let helperPath = config.helperPath?.isEmpty == false
            ? config.helperPath!
            : Self.defaultHelperPath
        let binary = helperPath.hasPrefix("/")
            ? URL(fileURLWithPath: helperPath)
            : repoRoot.appendingPathComponent(helperPath)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            XCTFail("Packaged speech helper missing at \(binary.path); run package first")
            return
        }

        let model = SpeechModelCatalog.defaultOption
        var arguments = [
            "--model", model.repoID,
            "--model-revision", model.revision,
            "--bench",
            "--seconds", "\(config.seconds)",
            "--cadence-ms", "\(config.cadenceMilliseconds)",
        ]
        if let wavPath = config.wavPath, !wavPath.isEmpty {
            arguments.append(contentsOf: ["--wav", wavPath])
        }
        if let cacheLimitMB = config.cacheLimitMB {
            arguments.append(contentsOf: ["--cache-limit-mb", "\(cacheLimitMB)"])
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutLog = BenchLineLog()
        let stderrLog = BenchLineLog()
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
        for line in stderrLog.snapshot() { print("speechd bench stderr: \(line)") }

        XCTAssertEqual(
            process.terminationStatus,
            0,
            "speechd bench failed with status \(process.terminationStatus)"
        )
        let benchLines = lines.filter { $0.hasPrefix("BENCH ") }
        let expectedMarks = [5, 15, 30, 60].filter { $0 <= config.seconds }
        XCTAssertEqual(benchLines.count, expectedMarks.count, lines.joined(separator: "\n"))
        for mark in expectedMarks {
            XCTAssertTrue(
                benchLines.contains { $0.contains("mark=\(mark)s ") },
                "missing BENCH mark=\(mark)s"
            )
        }
    }
}

private final class BenchLineLog: @unchecked Sendable {
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
