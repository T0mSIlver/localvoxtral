import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs the eval's `say` calls, directly or through the say proxy.
///
/// Under the Actions runner, anything xctest starts, launchd jobs included,
/// lists only the built-in voices, while the runner's shell lists the
/// downloaded ones (#960). With `LV_EVAL_SAY_PROXY_DIR` set, eval-e2e's shell
/// runs `scripts/ci/say-proxy.sh` on that directory, and each call becomes a
/// request it serves. Output goes to files either way; no pipe is read.
package enum EvalChildProcess {
    package struct Failure: Error, CustomStringConvertible {
        package let description: String
    }

    package static let proxyDirectoryVariable = "LV_EVAL_SAY_PROXY_DIR"

    package static var proxyDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment[proxyDirectoryVariable], !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Runs `executable` and returns its exit status.
    /// - Parameters:
    ///   - standardOutput: a file the child's stdout truncates and writes,
    ///     or nil to inherit ours (discarded through the proxy).
    ///   - discardStandardError: sends stderr to /dev/null. Through the
    ///     proxy, stderr's text is printed unless discarded.
    ///   - proxy: the say proxy's directory; `arguments` go to its `say`,
    ///     and `executable` is ignored.
    package static func run(
        _ executable: String,
        arguments: [String],
        standardOutput: String? = nil,
        discardStandardError: Bool = false,
        proxy: URL? = proxyDirectory,
        timeout: Duration = .seconds(120)
    ) throws -> Int32 {
        if let proxy {
            return try runThroughProxy(
                proxy, arguments: arguments, standardOutput: standardOutput,
                discardStandardError: discardStandardError, timeout: timeout
            )
        }
        return try runDirectly(
            executable, arguments: arguments, standardOutput: standardOutput,
            standardError: discardStandardError ? "/dev/null" : nil
        )
    }

    // MARK: - Say proxy

    /// A request's bytes: each argument followed by a NUL, which no argument
    /// can hold.
    package static func proxyRequest(arguments: [String]) -> Data {
        var data = Data()
        for argument in arguments {
            data.append(contentsOf: argument.utf8)
            data.append(0)
        }
        return data
    }

    private static func runThroughProxy(
        _ directory: URL,
        arguments: [String],
        standardOutput: String?,
        discardStandardError: Bool,
        timeout: Duration
    ) throws -> Int32 {
        let id = UUID().uuidString
        let requests = directory.appendingPathComponent("requests", isDirectory: true)
        let results = directory.appendingPathComponent("results", isDirectory: true)
        let status = results.appendingPathComponent("\(id).status")
        let output = results.appendingPathComponent("\(id).out")
        let errors = results.appendingPathComponent("\(id).err")
        defer {
            for file in [status, output, errors] {
                try? FileManager.default.removeItem(at: file)
            }
        }

        // Written under another name, then renamed: the proxy only picks up
        // complete `.req` files.
        let pending = requests.appendingPathComponent("\(id).tmp")
        try proxyRequest(arguments: arguments).write(to: pending)
        try FileManager.default.moveItem(at: pending, to: requests.appendingPathComponent("\(id).req"))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let text = try? String(contentsOf: status, encoding: .utf8),
                let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                if let standardOutput {
                    try? FileManager.default.removeItem(atPath: standardOutput)
                    try FileManager.default.moveItem(at: output, to: URL(fileURLWithPath: standardOutput))
                }
                if !discardStandardError || code == 64,
                    let text = try? String(contentsOf: errors, encoding: .utf8), !text.isEmpty
                {
                    print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
                }
                return code
            }
            guard clock.now < deadline else {
                throw Failure(
                    description: "say proxy at \(directory.path) did not answer within \(timeout); "
                        + "is scripts/ci/say-proxy.sh running?"
                )
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
