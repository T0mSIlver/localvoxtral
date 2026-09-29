import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs the eval's `say` calls, output to files so no pipe is read, and
/// reports the environment they inherit (#960).
package enum EvalChildProcess {
    /// Runs `executable` and returns its exit status.
    /// - Parameters:
    ///   - standardOutput: a file the child's stdout truncates and writes,
    ///     or nil to inherit ours.
    ///   - discardStandardError: sends stderr to /dev/null.
    package static func run(
        _ executable: String,
        arguments: [String],
        standardOutput: String? = nil,
        discardStandardError: Bool = false
    ) throws -> Int32 {
        try runDirectly(
            executable, arguments: arguments, standardOutput: standardOutput,
            standardError: discardStandardError ? "/dev/null" : nil
        )
    }

    // MARK: - Direct

    private static func runDirectly(
        _ executable: String,
        arguments: [String],
        standardOutput: String?,
        standardError: String?
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var handles: [FileHandle] = []
        defer { handles.forEach { try? $0.close() } }
        func writing(_ path: String) throws -> FileHandle {
            if path == "/dev/null" { return FileHandle.nullDevice }
            _ = FileManager.default.createFile(atPath: path, contents: nil)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            handles.append(handle)
            return handle
        }
        if let standardOutput {
            process.standardOutput = try writing(standardOutput)
        }
        if let standardError {
            process.standardError = try writing(standardError)
        }
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Environment report

    /// The variable names in `environment`, then the values of those that
    /// could steer which voices `say` sees (#960), with the home directory
    /// and user name masked for the public log.
    package static func environmentReport(
        _ environment: [String: String],
        home: String,
        user: String
    ) -> [String] {
        let names = environment.keys.sorted()
        let shown = names.filter { name in
            ["HOME", "TMPDIR", "CFFIXED_USER_HOME"].contains(name)
                || ["DYLD_", "__XPC_", "XPC_", "__CF"].contains { name.hasPrefix($0) }
        }
        return ["keys: " + names.joined(separator: " ")]
            + shown.map { "\($0)=\(masked(environment[$0] ?? "", home: home, user: user))" }
    }

    /// `environmentReport` for this process.
    package static func currentEnvironmentReport() -> [String] {
        var home = ""
        var user = ""
        if let entry = getpwuid(getuid()) {
            home = String(cString: entry.pointee.pw_dir)
            user = String(cString: entry.pointee.pw_name)
        }
        return environmentReport(ProcessInfo.processInfo.environment, home: home, user: user)
    }

    private static func masked(_ value: String, home: String, user: String) -> String {
        var value = value
        if home.count > 1 {
            value = value.replacingOccurrences(of: home, with: "<home>")
        }
        if user.count > 2 {
            value = value.replacingOccurrences(of: user, with: "<user>")
        }
        return value
    }
}
