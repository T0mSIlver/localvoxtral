import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)
/// Runs a program and waits for IT to exit, not for what it left running.
///
/// swift-corelibs-foundation's `Process` (Linux) learns of an exit when a
/// socket the child inherits reaches EOF, so a detached grandchild that keeps
/// the child's descriptors, such as the Vibe shim's exit watcher, holds
/// `terminationHandler` until the grandchild exits too. `waitpid` on the
/// child's pid does not wait for it. The child gets only descriptors 0 to 2,
/// as Vibe's own `close_fds` spawn gives a hook.
package enum SpawnAndWait {
    /// - Returns: the exit code, or the signal number for a child killed by
    ///   one, as `Process.terminationStatus` reports them.
    package static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String,
        output: String
    ) throws -> Int32 {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        posix_spawn_file_actions_addopen(&actions, 0, standardInput, O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, output, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        #if canImport(Darwin)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        #else
        // Not `addclosefrom_np`: the CI image's Glibc module (bookworm) does
        // not export it. glibc ignores a close action on a descriptor that
        // has been closed since.
        let open = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
        for fd in open.compactMap(Int32.init) where fd > 2 {
            posix_spawn_file_actions_addclose(&actions, fd)
        }
        #endif

        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EINVAL) }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD) }
        }
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : signal
    }
}
#endif
