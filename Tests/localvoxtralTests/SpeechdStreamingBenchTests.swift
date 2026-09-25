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
        let maxUtteranceSeconds: Int?
        /// Catalog repo to benchmark. Absent means the catalog default, which
        /// is what every run measured before a second model existed.
        let model: String?
        /// "speech" feeds a spoken passage from the system voice instead of the
        /// helper's synthetic noise, which decodes to no words and so cannot show
        /// when text appears (#486).
        let audio: String?
    }

    /// About twenty seconds of plain dictation. The bench loops it to fill the run.
    private static let spokenPassage = """
        Please open the settings file and change the step interval to two hundred \
        and forty milliseconds. Then run the benchmark again for each model, write \
        down the peak memory and the time to first text, and compare the numbers \
        with the ones from yesterday before we decide what the pane should say.
        """

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

        let model = config.model.flatMap(SpeechModelCatalog.option(forRepoID:))
            ?? SpeechModelCatalog.defaultOption
        if let requested = config.model, requested != model.repoID {
            XCTFail("\(requested) is not in SpeechModelCatalog; nothing to benchmark")
            return
        }
        print("BENCH model=\(model.repoID)")
        var arguments = [
            "--model", model.repoID,
            "--model-revision", model.revision,
            "--bench",
            "--seconds", "\(config.seconds)",
            "--cadence-ms", "\(config.cadenceMilliseconds)",
        ]
        let spokenAudio = config.audio == "speech"
        let spokenWAV = spokenAudio ? try Self.makeSpokenWAV(Self.spokenPassage) : nil
        defer { spokenWAV.map { try? FileManager.default.removeItem(at: $0) } }
        if let spokenWAV {
            arguments.append(contentsOf: ["--wav", spokenWAV.path])
        } else if let wavPath = config.wavPath, !wavPath.isEmpty {
            arguments.append(contentsOf: ["--wav", wavPath])
        }
        if let cacheLimitMB = config.cacheLimitMB {
            arguments.append(contentsOf: ["--cache-limit-mb", "\(cacheLimitMB)"])
        }
        if let maxUtteranceSeconds = config.maxUtteranceSeconds {
            arguments.append(contentsOf: ["--max-utterance-seconds", "\(maxUtteranceSeconds)"])
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
        let benchLines = lines.filter { $0.hasPrefix("BENCH mark=") }
        let expectedMarks = ([5, 15, 30, 60] + Array(stride(from: 120, through: config.seconds, by: 60)))
            .filter { $0 <= config.seconds }
        XCTAssertEqual(benchLines.count, expectedMarks.count, lines.joined(separator: "\n"))
        XCTAssertTrue(
            lines.contains { $0.hasPrefix("BENCH done ") },
            "missing BENCH done summary"
        )
        for mark in expectedMarks {
            XCTAssertTrue(
                benchLines.contains { $0.contains("mark=\(mark)s ") },
                "missing BENCH mark=\(mark)s"
            )
        }
        XCTAssertTrue(
            lines.contains { $0.hasPrefix("BENCH transcript sha256=") },
            "missing BENCH transcript digest"
        )
        let timeline = lines.first { $0.hasPrefix("BENCH timeline ") }
        XCTAssertNotNil(timeline, "missing BENCH timeline summary")
        if spokenAudio {
            XCTAssertFalse(
                timeline?.contains("first_text_s=none") ?? true,
                "spoken audio decoded to no text; the timing columns measured nothing"
            )
        }
    }

    private static func makeSpokenWAV(_ phrase: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechd-bench-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-o", url.path,
            "--file-format=WAVE",
            "--data-format=LEI16@16000",
            phrase,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "SpeechdStreamingBenchTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "/usr/bin/say failed; no spoken audio to bench"]
            )
        }
        return url
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
