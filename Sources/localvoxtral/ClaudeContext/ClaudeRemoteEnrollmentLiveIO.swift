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
