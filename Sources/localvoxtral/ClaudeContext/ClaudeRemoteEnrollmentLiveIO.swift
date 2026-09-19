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

/// The LOCAL herdr config, with the same discipline as the ssh-config
/// writer: `lstat` so a symlink is seen as one, `O_NOFOLLOW` on the temp
/// file, and an atomic same-directory rename.
///
/// The path is where herdr itself looks on macOS (`src/config/io.rs`):
/// `~/.config/herdr/config.toml`, with `herdr-dev` in place of `herdr` for a
/// development build. A user running a dev build has that directory; a user
/// who is not has nothing there, so its EXISTENCE is the discriminator — dev
/// first, release otherwise. RESIDUAL, same as the federation reader's
/// `XDG_STATE_HOME` one: a GUI app does not see the shell's
/// `XDG_CONFIG_HOME`, so a user who relocates herdr's config reads back as
/// "no config yet" and the append targets the default location only.
struct LiveClaudeLocalHerdrConfigFileSystem: ClaudeLocalHerdrConfigFileSystem {
    private let configDirectoryURL: URL
    private let configURL: URL

    init(homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let configRoot = homeDirectoryURL.appendingPathComponent(".config", isDirectory: true)
        let devDirectory = configRoot.appendingPathComponent("herdr-dev", isDirectory: true)
        let releaseDirectory = configRoot.appendingPathComponent("herdr", isDirectory: true)
        // A dev build's directory is only created by running one; its presence
        // as an actual DIRECTORY is the whole signal, and it wins because a
        // user running both reads the dev one. A non-directory at that path
        // (a file, a symlink, a socket) must not divert the write.
        let directory = ClaudeSocketGuard.metadata(ofPath: devDirectory.path)?.isDirectory == true
            ? devDirectory
            : releaseDirectory
        configDirectoryURL = directory
        configURL = directory.appendingPathComponent("config.toml", isDirectory: false)
    }

    func readState() throws -> ClaudeLocalHerdrConfigState {
        // lstat, not stat: an atomic rename would replace a symlink rather
        // than follow it, so the writer has to see links as links.
        let directoryMetadata = ClaudeSocketGuard.metadata(ofPath: configDirectoryURL.path)
        let configMetadata = ClaudeSocketGuard.metadata(ofPath: configURL.path)
        let data: Data?
        if configMetadata != nil, configMetadata?.isSymlink != true {
            // Throws rather than reporting nil: nil means "no config", and a
            // file that exists but cannot be read is not absent.
            data = try Data(contentsOf: configURL)
        } else {
            data = nil
        }
        var permissions: UInt16?
        if data != nil,
           let number = try? FileManager.default
               .attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber {
            permissions = number.uint16Value
        }
        return ClaudeLocalHerdrConfigState(
            directoryExists: directoryMetadata?.isDirectory == true,
            configData: data,
            configPermissions: permissions,
            configIsSymlink: configMetadata?.isSymlink == true
        )
    }

    func createConfigDirectory(permissions: UInt16) throws {
        try FileManager.default.createDirectory(
            at: configDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: permissions)]
        )
    }

    func atomicWriteConfig(_ data: Data, permissions: UInt16, expectedConfigPresent: Bool) throws {
        let temporaryURL = configDirectoryURL.appendingPathComponent(
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
        // Re-lstat the destination AFTER the payload is durable and BEFORE
        // the rename: a swap between the service's `readState` and now — a
        // planted symlink (whose replace would destroy the user's link
        // layout), a file appearing where none was, or the file vanishing —
        // refuses fail-closed instead of renaming over it.
        let current = ClaudeSocketGuard.metadata(ofPath: configURL.path)
        let stillExpected: Bool = if expectedConfigPresent {
            current.map { !$0.isSymlink && !$0.isDirectory && !$0.isSocket } ?? false
        } else {
            current == nil
        }
        guard stillExpected else { throw POSIXFailure(operation: "revalidate", code: EPERM) }
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
    private let homeURL: URL
    private let relativePath: String

    init(
        relativePath: String,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        homeURL = homeDirectoryURL
        self.relativePath = relativePath
        fileURL = homeDirectoryURL.appendingPathComponent(relativePath, isDirectory: false)
        directoryURL = fileURL.deletingLastPathComponent()
    }

    func readState() throws -> ClaudeShellRCState {
        let fileMetadata = ClaudeSocketGuard.metadata(ofPath: fileURL.path)
        // EVERY component from home down, not just the immediate parent. For
        // fish the file is `~/.config/fish/conf.d/localvoxtral.fish`, and the
        // standard dotfiles layout symlinks `~/.config` itself — checking only
        // `conf.d` walked straight through it and planted the file in the
        // user's repo (review finding M3). For zsh and bash the parent IS home,
        // which is why that half of the old check was vacuous.
        let intermediateIsSymlink = Self.anyComponentIsSymlink(
            under: homeURL, relativePath: relativePath
        )
        let data: Data?
        if fileMetadata != nil, fileMetadata?.isSymlink != true, !intermediateIsSymlink {
            // NOT `try?`: a file that exists and cannot be read must reach the
            // writer as "unreadable", never as an empty file (review finding
            // M2). `readState` reports it as existing with no data, and the
            // writer turns that into a refusal.
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
            directoryExists: ClaudeSocketGuard.metadata(ofPath: directoryURL.path)?
                .isDirectory == true,
            directoryIsSymlink: intermediateIsSymlink,
            data: data,
            permissions: permissions
        )
    }

    /// Is any directory between `home` and the file a symlink?
    ///
    /// Pure over the two arguments and `lstat`, so the fish layout is testable
    /// against a real temp tree.
    static func anyComponentIsSymlink(under home: URL, relativePath: String) -> Bool {
        var current = home
        let components = relativePath.split(separator: "/").map(String.init)
        // The leaf is the file itself; its own symlink-ness is reported
        // separately so the writer can name that case.
        for component in components.dropLast() {
            current = current.appendingPathComponent(component, isDirectory: true)
            guard let metadata = ClaudeSocketGuard.metadata(ofPath: current.path) else {
                // Not created yet — nothing to follow, and `createDirectory`
                // will make it under a path we just proved link-free.
                continue
            }
            if metadata.isSymlink { return true }
        }
        return false
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
        runCapturingOutput(
            executableURL: URL(fileURLWithPath: "/usr/bin/dscl"),
            arguments: [".", "-read", "/Users/\(NSUserName())", "UserShell"]
        )
    }

    /// Runs a short command and returns its output, never running the
    /// caller's run loop and never waiting past `timeout`. Settings builds its
    /// consent sentences inside SwiftUI's view update, on the main thread:
    ///
    /// * `Process.waitUntilExit()` spins the run loop, and on macOS 26 that
    ///   re-entered the update cycle and crashed the app (field crash
    ///   2026-09-18, opening a host's Update panel);
    /// * an unbounded pipe read would instead freeze it for as long as a
    ///   stalled `dscl` stays silent.
    ///
    /// `ClaudePluginInstallService.processRunner` already does both right
    /// (`poll()`-gated reads, semaphore exit, SIGTERM then SIGKILL).
    static func runCapturingOutput(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = 5
    ) -> String? {
        let run = ClaudePluginInstallService.processRunner(
            executableURL: executableURL,
            timeout: timeout
        )
        do {
            let result = try run(.init(arguments: arguments))
            guard result.exitCode == 0 else {
                Log.claudeContext.error(
                    "Login shell probe exited with status \(result.exitCode, privacy: .public); using $SHELL"
                )
                return nil
            }
            return result.message
        } catch ClaudePluginInstallService.ServiceError.commandTimedOut {
            Log.claudeContext.error("Login shell probe gave no answer within \(timeout, privacy: .public)s; using $SHELL")
            return nil
        } catch {
            // Not `error` itself: its arguments carry the user name.
            Log.claudeContext.error("Login shell probe could not run; using $SHELL")
            return nil
        }
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
            sshConfigFileSystem: LiveClaudeRemoteSSHConfigFileSystem(),
            localHerdrConfigFileSystem: LiveClaudeLocalHerdrConfigFileSystem()
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
            if !invocation.environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(
                    invocation.environment,
                    uniquingKeysWith: { _, requested in requested }
                )
            }

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
