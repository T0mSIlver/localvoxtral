import Foundation

/// `python3` for the Vibe shim tests: a link, under the name the shim's
/// fallback looks for, to the interpreter `/usr/bin/python3` itself runs. On macOS that path
/// is an `xcrun` trampoline, and under the stripped environment the shim runs
/// in (no `TMPDIR`, a temporary `HOME`) it was most of each hook's cost on the
/// build host. The shim still finds the interpreter through its `command -v
/// python3` fallback, under the same name check.
package enum VibeTestPython {
    package static let directory: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-python-\(UUID().uuidString)")
        atexit { try? FileManager.default.removeItem(at: VibeTestPython.directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("python3").path, withDestinationPath: resolved()
        )
        return directory
    }()

    package static var executable: URL { directory.appendingPathComponent("python3") }

    /// The interpreter behind `/usr/bin/python3`, or that path when it will not say.
    private static func resolved() -> String {
        let fallback = "/usr/bin/python3"
        let answer = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-python-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: answer) }
        guard FileManager.default.createFile(atPath: answer.path, contents: nil),
              let sink = try? FileHandle(forWritingTo: answer) else { return fallback }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fallback)
        process.arguments = ["-c", "import sys; print(sys.executable)"]
        process.standardOutput = sink
        process.standardError = FileHandle.nullDevice
        guard (try? process.runUntilExit()) != nil, process.terminationStatus == 0 else { return fallback }
        try? sink.close()
        let path = ((try? String(contentsOf: answer, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : fallback
    }
}
