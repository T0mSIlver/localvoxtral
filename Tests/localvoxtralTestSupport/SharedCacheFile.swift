import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A file in a cache under the real home that several xctest processes fill
/// at once (#442): the eval TTS cache and the Hugging Face hub (#1525).
package enum SharedCacheFile {
    /// Moves `file` to `destination` with one rename, so a reader sees the
    /// whole file or none. Two processes that missed the same entry both
    /// succeed: the later rename replaces the earlier one's file, which holds
    /// the same content, where `moveItem` would throw.
    package static func publish(_ file: URL, at destination: URL) throws {
        // Staged next to the destination first: the rename below is atomic
        // only within one volume, and a download's file may be elsewhere.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)-\(destination.lastPathComponent)")
        try FileManager.default.moveItem(at: file, to: staging)
        guard rename(staging.path, destination.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: staging)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}
