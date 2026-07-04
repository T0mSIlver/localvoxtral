import Foundation

/// Reads pipe data with POSIX `read(2)` instead of `FileHandle.availableData`.
///
/// `availableData` raises an Objective-C `NSFileHandleOperationException` when
/// the descriptor errors or closes mid-read. That exception is uncatchable
/// from Swift, so it aborts the whole app — field-hit as a SIGABRT in
/// `PipeLineReader` during a managed mlx-lm install. `read(2)` reports the
/// same conditions as return values instead, which callers can treat as EOF.
enum POSIXPipeRead {
    /// Blocks until data is available, then returns it. Returns empty Data on
    /// EOF *or any read error* — for a pipe reader both mean "stop reading".
    static func nextChunk(fromDescriptor descriptor: Int32) -> Data {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { pointer in
                read(descriptor, pointer.baseAddress, pointer.count)
            }
            if count > 0 {
                return Data(bytes: buffer, count: count)
            }
            if count == 0 {
                return Data()
            }
            if errno == EINTR {
                continue
            }
            return Data()
        }
    }
}
