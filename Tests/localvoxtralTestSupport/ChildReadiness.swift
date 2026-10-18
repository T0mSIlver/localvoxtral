import Foundation

/// A signal a child shell script sends once it is ready, so a test acts on
/// the child only after it has run the lines before `signal` (for example
/// `trap '' TERM`). Process registration alone can precede those lines, and
/// a SIGTERM that lands first kills the shell by default, skipping the
/// escalation the test means to prove. Nothing here sleeps or polls.
///
/// The script runs `signal` on its own line; the test awaits `waitUntilReady`.
package final class ChildReadiness: Sendable {
    package let path: String
    private let descriptor: Int32

    package init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("lvx-ready-\(UUID().uuidString)").path
        guard mkfifo(path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Read-write, so the open neither blocks nor lets the script's write
        // block, and a read waits for a byte whoever sends it.
        descriptor = open(path, O_RDWR)
        guard descriptor >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            unlink(path)
            throw POSIXError(code)
        }
    }

    deinit {
        close(descriptor)
        unlink(path)
    }

    /// The shell line that tells the test the child got this far.
    package var signal: String { "echo R > '\(path)'" }

    /// Sends the byte that ends a wait without the child being ready, for a
    /// runner that returned early.
    package func releaseWaiter() {
        _ = write(descriptor, "X", 1)
    }

    /// Whether the child signalled, or false when `releaseWaiter` ended the
    /// wait first. Suspends on a blocking read off the cooperative pool.
    package func waitUntilReady() async -> Bool {
        let descriptor = descriptor
        return await Task.detached {
            var byte: UInt8 = 0
            while true {
                let count = read(descriptor, &byte, 1)
                if count == 1 { return byte == UInt8(ascii: "R") }
                if count < 0 && errno == EINTR { continue }
                return false
            }
        }.value
    }
}
