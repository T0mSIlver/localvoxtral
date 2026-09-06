import Foundation

#if canImport(Darwin)
import Darwin

struct LiveClaudeRemoteSSHConfigFileSystem: ClaudeRemoteSSHConfigFileSystem {
    private let sshDirectoryURL: URL
    private let configURL: URL

    init(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        sshDirectoryURL = homeDirectoryURL.appendingPathComponent(".ssh", isDirectory: true)
        configURL = sshDirectoryURL.appendingPathComponent("config", isDirectory: false)
    }

    func readState() throws -> ClaudeRemoteSSHConfigState {
        let fileManager = FileManager.default
        // lstat, not stat: the service's trust gate needs to see symlinks as
        // symlinks (a rename would replace the link, not its target).
        let directoryMetadata = ClaudeSocketGuard.metadata(ofPath: sshDirectoryURL.path)
        let configMetadata = ClaudeSocketGuard.metadata(ofPath: configURL.path)
        let directoryExists = directoryMetadata?.isDirectory == true
        let data: Data?
        if configMetadata != nil, configMetadata?.isSymlink != true {
            data = try Data(contentsOf: configURL)
        } else {
            data = nil
        }
        let permissions: UInt16?
        if data != nil,
           let number = try fileManager.attributesOfItem(atPath: configURL.path)[.posixPermissions]
                as? NSNumber {
            permissions = number.uint16Value
        } else {
            permissions = nil
        }
        return ClaudeRemoteSSHConfigState(
            directoryExists: directoryExists,
            configData: data,
            configPermissions: permissions,
            directoryIsSymlink: directoryMetadata?.isSymlink == true,
            directoryOwnedByCurrentUser:
                directoryMetadata.map { $0.ownerUID == UInt32(geteuid()) } ?? true,
            directoryPermissions: directoryMetadata?.mode,
            configIsSymlink: configMetadata?.isSymlink == true
        )
    }

    func createSSHDirectory(permissions: UInt16) throws {
        try FileManager.default.createDirectory(
            at: sshDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: permissions)]
        )
    }

    func atomicWriteConfig(_ data: Data, permissions: UInt16) throws {
        let temporaryURL = sshDirectoryURL.appendingPathComponent(
            ".config.localvoxtral.\(UUID().uuidString)",
            isDirectory: false
        )
        let descriptor = temporaryURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw POSIXFailure(operation: "open", code: errno) }
        var renamed = false
        defer {
            close(descriptor)
            if !renamed { _ = temporaryURL.path.withCString { unlink($0) } }
        }
        guard fchmod(descriptor, mode_t(permissions)) == 0 else {
            throw POSIXFailure(operation: "fchmod", code: errno)
        }
        try data.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Self.retryingOnEINTR {
                    Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        raw.count - offset
                    )
                }
                guard written > 0 else {
                    throw POSIXFailure(operation: "write", code: errno)
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXFailure(operation: "fsync", code: errno) }
        let moved = temporaryURL.path.withCString { source in
            configURL.path.withCString { destination in rename(source, destination) }
        }
        guard moved == 0 else {
            throw POSIXFailure(operation: "rename", code: errno)
        }
        renamed = true
    }

    private struct POSIXFailure: Error, CustomStringConvertible {
        var operation: String
        var code: Int32
        var description: String { "\(operation) failed with errno \(code)" }
    }

    private static func retryingOnEINTR(_ body: () -> Int) -> Int {
        while true {
            let result = body()
            if result == -1, errno == EINTR { continue }
            return result
        }
    }
}

/// The user's shell rc file, with the same discipline as the ssh-config
/// writer: `lstat` so a symlink is seen as one, `O_NOFOLLOW` on the temp file,
/// and an atomic rename.
///
/// Deliberately NOT shared with that writer despite the shape: `~/.ssh` has
/// trust rules of its own (owner and group-write checks that OpenSSH itself
/// enforces), and an rc file has none of them. Merging the two would mean one
/// of the two sets of rules applying where it does not belong.
struct LiveClaudeShellRCFileSystem: ClaudeShellRCFileSystem {
    private let fileURL: URL
    private let directoryURL: URL

    /// - Parameter relativePath: from `ClaudeShellRCSetup.relativeRCPath`, so
    ///   the shell rule and the file I/O cannot disagree about which file this
    ///   is.
    init(
        relativePath: String,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        fileURL = homeDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
        directoryURL = fileURL.deletingLastPathComponent()
    }

    func readState() throws -> ClaudeShellRCState {
        let directoryMetadata = ClaudeSocketGuard.metadata(ofPath: directoryURL.path)
        let fileMetadata = ClaudeSocketGuard.metadata(ofPath: fileURL.path)
        let data: Data?
        if fileMetadata != nil, fileMetadata?.isSymlink != true {
            data = try? Data(contentsOf: fileURL)
        } else {
            data = nil
        }
        var permissions: UInt16?
        if data != nil,
           let number = try? FileManager.default
               .attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber {
            permissions = number.uint16Value
        }
        return ClaudeShellRCState(
            fileExists: fileMetadata != nil,
            fileIsSymlink: fileMetadata?.isSymlink == true,
            directoryExists: directoryMetadata?.isDirectory == true,
            directoryIsSymlink: directoryMetadata?.isSymlink == true,
            data: data,
            permissions: permissions
        )
    }

    func createDirectory(permissions: UInt16) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: permissions)]
        )
    }

    func atomicWrite(_ data: Data, permissions: UInt16) throws {
        let temporaryURL = directoryURL.appendingPathComponent(
            ".localvoxtral-rc.\(UUID().uuidString)", isDirectory: false
        )
        let descriptor = temporaryURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw ShellRCPOSIXFailure(operation: "open", code: errno) }
        var renamed = false
        defer {
            close(descriptor)
            if !renamed { _ = temporaryURL.path.withCString { unlink($0) } }
        }
        guard fchmod(descriptor, mode_t(permissions)) == 0 else {
            throw ShellRCPOSIXFailure(operation: "fchmod", code: errno)
        }
        try data.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(
                    descriptor, baseAddress.advanced(by: offset), raw.count - offset
                )
                if written == -1, errno == EINTR { continue }
                guard written > 0 else {
                    throw ShellRCPOSIXFailure(operation: "write", code: errno)
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw ShellRCPOSIXFailure(operation: "fsync", code: errno)
        }
        let moved = temporaryURL.path.withCString { source in
            fileURL.path.withCString { destination in rename(source, destination) }
        }
        guard moved == 0 else { throw ShellRCPOSIXFailure(operation: "rename", code: errno) }
        renamed = true
    }

    private struct ShellRCPOSIXFailure: Error, CustomStringConvertible {
        var operation: String
        var code: Int32
        var description: String { "\(operation) failed with errno \(code)" }
    }
}

/// The user's login shell, from Directory Services — the same answer
/// `chsh -s` writes and `Terminal.app` obeys.
///
/// `$SHELL` is the fallback and NOT the primary: this app runs from a GUI
/// launch, where `$SHELL` is inherited from launchd and can be stale after a
/// `chsh`. `dscl` is asked first and the environment only backs it up.
enum ClaudeLoginShellReader {
    /// - Parameter runDSCL: returns `dscl`'s RAW output, which `parse` reads.
    ///   Splitting it that way keeps the parser testable without a process and
    ///   keeps the process out of every test that forgets to inject.
    static func loginShellPath(
        runDSCL: () -> String? = liveDSCL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let output = runDSCL(), let path = parse(output) {
            return path
        }
        let fallback = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback?.hasPrefix("/") == true ? fallback : nil
    }

    /// `dscl . -read /Users/<me> UserShell` prints `UserShell: /bin/zsh`.
    /// Returns that line verbatim; `parse` turns it into a path.
    static func liveDSCL() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = [".", "-read", "/Users/\(NSUserName())", "UserShell"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        // `POSIXPipeRead`, never `FileHandle.availableData` (banned repo-wide,
        // PR #60). `dscl`'s answer is one short line, so one chunk is the whole
        // of it; a longer answer is not one this parser would accept anyway.
        let data = POSIXPipeRead.nextChunk(
            fromDescriptor: output.fileHandleForReading.fileDescriptor
        )
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `UserShell: /bin/zsh` → `/bin/zsh`.
    static func parse(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2,
                  fields[0].trimmingCharacters(in: .whitespaces) == "UserShell"
            else { continue }
            let value = fields[1].trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("/") ? value : nil
        }
        return nil
    }
}

extension ClaudeRemoteEnrollmentService {
    static func live() -> ClaudeRemoteEnrollmentService {
        ClaudeRemoteEnrollmentService(
            runner: processRunner(),
            sshConfigFileSystem: LiveClaudeRemoteSSHConfigFileSystem()
        )
    }

    /// Runs `ssh` with stdin preloaded before launch, so the token-bearing
    /// script is never written after a child could close its pipe.
    static func processRunner(
        sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh")
    ) -> Runner {
        { invocation in
            // The preload below writes the whole script into the pipe before
            // the child exists to drain it; past the kernel pipe buffer that
            // write would block forever with no timeout running yet. Scripts
            // here are a few hundred bytes — refuse loudly long before the
            // buffer, rather than deadlock, if a future plan grows one.
            guard invocation.standardInput.count <= 8 * 1024 else {
                throw RunnerFailure.outputTooLarge(
                    capBytes: 8 * 1024,
                    message: "generated setup script exceeds the stdin preload budget"
                )
            }
            let process = Process()
            process.executableURL = sshExecutableURL
            process.arguments = Array(invocation.argv.dropFirst())

            let input = Pipe()
            process.standardInput = input
            try input.fileHandleForWriting.write(contentsOf: invocation.standardInput)
            try input.fileHandleForWriting.close()

            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()

            func waitForExit(_ window: TimeInterval) -> Bool {
                exited.wait(timeout: .now() + max(window, 0)) == .success
            }

            func stopChild() {
                _ = ClaudePluginInstallService.terminateBounded(
                    gracePeriod: ClaudePluginInstallService.terminationGracePeriod,
                    terminate: { process.terminate() },
                    kill: {
                        let pid = process.processIdentifier
                        if pid > 0, process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
                    },
                    waitForExit: waitForExit
                )
            }

            let descriptor = output.fileHandleForReading.fileDescriptor
            let deadline = Date().addingTimeInterval(max(invocation.timeout, 0))
            var collected = Data()
            var timedOut = false
            var outputTooLarge = false

            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    timedOut = true
                    break
                }
                var descriptorPoll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptorPoll, 1, Int32(remaining * 1_000))
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 {
                    timedOut = true
                    break
                }
                let chunk = POSIXPipeRead.nextChunk(fromDescriptor: descriptor)
                if chunk.isEmpty { break }
                collected.append(chunk)
                if collected.count > maxCapturedOutputBytes {
                    outputTooLarge = true
                    break
                }
            }

            if !timedOut, !outputTooLarge,
               !waitForExit(deadline.timeIntervalSinceNow) {
                timedOut = true
            }
            let message = String(decoding: collected.prefix(maxCapturedOutputBytes), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if timedOut {
                stopChild()
                throw RunnerFailure.timedOut(seconds: invocation.timeout, message: message)
            }
            if outputTooLarge {
                stopChild()
                throw RunnerFailure.outputTooLarge(
                    capBytes: maxCapturedOutputBytes,
                    message: message
                )
            }
            return RunResult(
                exitCode: process.terminationStatus,
                message: String(message.prefix(2_000))
            )
        }
    }
}
#endif
