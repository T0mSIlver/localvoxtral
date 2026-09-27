import ClaudeHookPublisherCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest

/// The ancestor walk against a REAL process tree, spawned the way Vibe spawns a
/// hook (`vibe/core/hooks/executor.py`: `create_subprocess_shell(command,
/// start_new_session=True)`; the Unified Harness runner spawns the same way,
/// `_foreign_hooks.py` `_run_command`, read at 0.5.1), with the command
/// `hooks.toml` ships. The seamed
/// tests in `VibeHookPublisherTests` describe that tree from reading; this one
/// asks the kernel.
final class VibeHookProcessTreeTests: XCTestCase {
    func testTheShippedHookCommandWalksBackToTheProcessThatSpawnedIt() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-tree-\(UUID().uuidString)")
        let scriptDirectory = home.appendingPathComponent(".vibe/localvoxtral")
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // A stand-in shim: report the pid the real shim hands the publisher
        // (`$PPID`) and its own, then stay alive until released so the tree
        // can be read.
        let report = home.appendingPathComponent("report")
        let release = home.appendingPathComponent("release")
        XCTAssertEqual(mkfifo(release.path, 0o600), 0)
        let shim = """
        #!/bin/sh
        echo "$$ $PPID" > "\(report.path).tmp" && mv "\(report.path).tmp" "\(report.path)"
        read _ < "\(release.path)"
        """
        try shim.write(to: scriptDirectory.appendingPathComponent("publish.sh"), atomically: true, encoding: .utf8)

        let command = try shippedHookCommand()
        let child = try spawnInNewSession(shell: command, home: home.path)
        defer {
            // Opening the fifo for writing releases the shim's `read`.
            let fd = open(release.path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
            kill(-child, SIGKILL)
            var status: Int32 = 0
            waitpid(child, &status, 0)
        }

        let pids = try waitForReport(at: report)
        let ownSession = getsid(pids.shim)
        XCTAssertEqual(ownSession, child, "the hook runs in the session Vibe created for it")

        let found = ClaudeHookPublisher.vibeAncestorPID(
            startingAt: pids.shimParent,
            ownSession: ownSession,
            processFacts: { ClaudeHookPublisher.processFacts(forProcess: $0) }
        )
        XCTAssertEqual(found, getpid(), "the walk must end on the process that spawned the hook")
    }

    private func shippedHookCommand() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let block = try String(contentsOf: root.appendingPathComponent("integrations/vibe/hooks.toml"), encoding: .utf8)
        let line = try XCTUnwrap(block.split(separator: "\n").first { $0.hasPrefix("command = ") })
        return String(line.dropFirst(#"command = ""#.count).dropLast())
            .replacingOccurrences(of: #"\""#, with: "\"")
    }

    private func spawnInNewSession(shell command: String, home: String) throws -> pid_t {
        #if canImport(Darwin)
        var attributes: posix_spawnattr_t?
        #else
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        #if canImport(Darwin)
        let setsid = Int16(POSIX_SPAWN_SETSID)
        #else
        // glibc's spawn.h defines it only under _GNU_SOURCE, which Swift's
        // Glibc module does not import.
        let setsid: Int16 = 0x80
        #endif
        XCTAssertEqual(posix_spawnattr_setflags(&attributes, setsid), 0)

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [Int32(0), 1, 2] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0)
        }

        let arguments = ["/bin/sh", "-c", command]
        let environment = ["HOME=\(home)", "PATH=/usr/bin:/bin"]
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", &actions, &attributes, &argv, &envp)
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EINVAL) }
        return pid
    }

    private func waitForReport(at url: URL) throws -> (shim: pid_t, shimParent: pid_t) {
        // Bounded by attempts, not by the clock: the shim writes within
        // milliseconds or never.
        for _ in 0..<2_000 {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let fields = text.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
                if fields.count == 2 { return (fields[0], fields[1]) }
            }
            usleep(5_000)
        }
        throw HookNeverReported()
    }

    private struct HookNeverReported: Error, CustomStringConvertible {
        var description: String { "the hook never reported its pids" }
    }
}
