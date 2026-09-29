import Foundation
import XCTest
import localvoxtralCore
#if canImport(Glibc)
import Glibc
#endif

/// The packaged `localvoxtral-speechd` (built by `remote-build.sh package`),
/// launched by a live suite on a port of its choosing. The speechd
/// integration suite and the term-recall eval share it.
package final class PackagedSpeechHelper: @unchecked Sendable {
    package struct LaunchError: Error, CustomStringConvertible {
        package let description: String
    }

    package let process: Process
    package let stderrLog: SpeechHelperLineLog

    private init(process: Process, stderrLog: SpeechHelperLineLog) {
        self.process = process
        self.stderrLog = stderrLog
    }

    /// Starts the helper and returns once it logs its ready line. Throws with
    /// the helper's stderr tail when it exits or stays silent past
    /// `readyTimeout`; the process is stopped before the throw.
    package static func launch(
        binary: URL,
        model: String,
        port: UInt16,
        extraArguments: [String] = [],
        readyTimeout: TimeInterval
    ) async throws -> PackagedSpeechHelper {
        let process = Process()
        process.executableURL = binary
        var arguments = [
            "--model", model,
            "--port", "\(port)",
        ]
        if let revision = SpeechModelCatalog.option(forRepoID: model)?.revision {
            arguments.append(contentsOf: ["--model-revision", revision])
        }
        process.arguments = arguments + extraArguments

        let stderr = Pipe()
        process.standardError = stderr
        let readyOrExited = XCTestExpectation(description: "speech helper ready or exited")
        readyOrExited.assertForOverFulfill = false
        let ready = SpeechHelperReadyFlag()
        let stderrLog = SpeechHelperLineLog()
        let readyLine = "ready on 127.0.0.1:\(port)"
        let reader = PipeLineReader(fileHandle: stderr.fileHandleForReading) { line in
            stderrLog.append(line)
            if line.contains(readyLine), ready.set() {
                readyOrExited.fulfill()
            }
        }
        process.terminationHandler = { _ in readyOrExited.fulfill() }

        try process.run()
        reader.start()
        let helper = PackagedSpeechHelper(process: process, stderrLog: stderrLog)

        _ = await XCTWaiter.fulfillment(of: [readyOrExited], timeout: readyTimeout)
        guard ready.value else {
            let status = process.isRunning
                ? "still running, no ready line after \(Int(readyTimeout))s"
                : "exited with status \(process.terminationStatus)"
            await helper.stop()
            throw LaunchError(description: """
                Speech helper failed to become ready (\(status)). stderr tail:
                \(stderrLog.tail(30))
                """)
        }
        return helper
    }

    /// SIGTERM, then SIGKILL if the helper is still up 10 s later.
    package func stop() async {
        if process.isRunning {
            process.terminate()
        }
        let reaped = XCTestExpectation(description: "speech helper exited after SIGTERM")
        let process = self.process
        DispatchQueue.global().async {
            process.waitUntilExit()
            reaped.fulfill()
        }
        _ = await XCTWaiter.fulfillment(of: [reaped], timeout: 10)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}

package final class SpeechHelperLineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    package func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    package func tail(_ count: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.suffix(count).joined(separator: "\n")
    }

    /// Every line so far that contains `fragment`.
    package func lines(containing fragment: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines.filter { $0.contains(fragment) }
    }
}

private final class SpeechHelperReadyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !storage else { return false }
        storage = true
        return true
    }
}
