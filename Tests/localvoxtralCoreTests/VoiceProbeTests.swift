import Foundation
import XCTest

/// Holds an xctest process of this package alive for eval-e2e's voice probe
/// (#960): `say -v ?` lists only the built-in voices while the eval's xctest
/// runs, whoever spawns `say`. Runs only with LV_VOICE_PROBE_MARKER set.
final class VoiceProbeTests: XCTestCase {
    func testHoldTheProcessWhileTheShellListsVoices() throws {
        guard let marker = ProcessInfo.processInfo.environment["LV_VOICE_PROBE_MARKER"] else {
            throw XCTSkip("eval-e2e's voice probe sets LV_VOICE_PROBE_MARKER")
        }
        print("voice probe in xctest: say lists \(try Self.voiceCount()) voices at start")
        FileManager.default.createFile(atPath: marker, contents: nil)
        Thread.sleep(forTimeInterval: 10)
        print("voice probe in xctest: say lists \(try Self.voiceCount()) voices after 10 s")
        Thread.sleep(forTimeInterval: 10)
    }

    /// `say -v ?` lines, through a file (no pipe is read).
    private static func voiceCount() throws -> Int {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("lv-voice-probe-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: output) }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return try String(contentsOf: output, encoding: .utf8).split(separator: "\n").count
    }
}
