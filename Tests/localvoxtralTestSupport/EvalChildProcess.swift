import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs the eval's `say` calls, directly or as launchd jobs.
///
/// Under the Actions runner, `say -v ?` spawned from xctest lists only the
/// built-in voices, while the runner's shell and a `launchctl submit` job
/// list the downloaded ones (#960). With `LV_EVAL_SAY_VIA_LAUNCHD=1`, each
/// call is submitted to launchd instead, so `say` inherits nothing from
/// xctest. Output goes to files either way; no pipe is read.
package enum EvalChildProcess {
    package struct Failure: Error, CustomStringConvertible {
        package let description: String
    }

    package static let launchdGate = "LV_EVAL_SAY_VIA_LAUNCHD"

    package static var launchdRequested: Bool {
        ProcessInfo.processInfo.environment[launchdGate] == "1"
    }

    /// Runs `executable` and returns its exit status.
    /// - Parameters:
    ///   - standardOutput: a file the child's stdout truncates and writes,
    ///     or nil to inherit ours (discarded under launchd).
    ///   - discardStandardError: sends stderr to /dev/null. Under launchd,
    ///     stderr goes to a file whose text is printed unless discarded.
    package static func run(
        _ executable: String,
        arguments: [String],
        standardOutput: String? = nil,
        discardStandardError: Bool = false,
        viaLaunchd: Bool = launchdRequested,
        timeout: Duration = .seconds(120)
    ) throws -> Int32 {
        if viaLaunchd {
            return try runViaLaunchd(
                executable, arguments: arguments, standardOutput: standardOutput,
                discardStandardError: discardStandardError, timeout: timeout
            )
        }
        return try runDirectly(
            executable, arguments: arguments, standardOutput: standardOutput,
            standardError: discardStandardError ? "/dev/null" : nil
        )
    }

    // MARK: - launchd

    /// The files one launchd job writes, in a directory of its own.
    package struct JobFiles {
        package let directory: URL
        package var status: URL { directory.appendingPathComponent("status") }
        package var standardError: URL { directory.appendingPathComponent("stderr") }

        package init(directory: URL) {
            self.directory = directory
        }
    }

    /// The `/bin/sh -c` script a job runs: the command, then its exit status
    /// written to `status` through a rename, so a reader never sees half a
    /// number. launchd restarts a `submit` job that exits, so a rerun that
    /// finds `status` does nothing.
    package static func jobScript(
        executable: String,
        arguments: [String],
        standardOutput: String?,
        files: JobFiles
    ) -> String {
        let status = shellQuoted(files.status.path)
        let pending = shellQuoted(files.status.path + ".tmp")
        let command = ([executable] + arguments).map(shellQuoted).joined(separator: " ")
        let output = shellQuoted(standardOutput ?? "/dev/null")
        let errors = shellQuoted(files.standardError.path)
        return "[ -e \(status) ] || { \(command) >\(output) 2>\(errors); "
            + "echo $? >\(pending); mv \(pending) \(status); }"
    }

    /// `launchctl` arguments that submit `script` under `label`.
    package static func submitArguments(label: String, script: String) -> [String] {
        ["submit", "-l", label, "--", "/bin/sh", "-c", script]
    }

    /// Single-quotes `value` for `/bin/sh`.
    package static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func runViaLaunchd(
        _ executable: String,
        arguments: [String],
        standardOutput: String?,
        discardStandardError: Bool,
        timeout: Duration
    ) throws -> Int32 {
        let label = "com.localvoxtral.eval.\(UUID().uuidString)"
        let files = JobFiles(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("lv-launchd-\(UUID().uuidString)", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let script = jobScript(
            executable: executable, arguments: arguments,
            standardOutput: standardOutput, files: files
        )
        let submitted = try runDirectly(
            "/bin/launchctl", arguments: submitArguments(label: label, script: script),
            standardOutput: "/dev/null", standardError: files.standardError.path
        )
        guard submitted == 0 else {
            let errors = (try? String(contentsOf: files.standardError, encoding: .utf8)) ?? ""
            throw Failure(
                description: "launchctl submit failed (status \(submitted)); it needs the account's "
                    + "GUI login session: \(errors)"
            )
        }
        defer {
            _ = try? runDirectly(
                "/bin/launchctl", arguments: ["remove", label],
                standardOutput: "/dev/null", standardError: "/dev/null"
            )
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let text = try? String(contentsOf: files.status, encoding: .utf8),
                let status = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                if !discardStandardError,
                    let errors = try? String(contentsOf: files.standardError, encoding: .utf8),
                    !errors.isEmpty
                {
                    print(errors, terminator: errors.hasSuffix("\n") ? "" : "\n")
                }
                return status
            }
            guard clock.now < deadline else {
                throw Failure(description: "launchd job \(executable) did not finish within \(timeout)")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
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
