import Darwin
import Foundation
import MLX
import MLXNN

/// Keeps a served model's weights in RAM for the life of the helper. Under memory
/// pressure macOS compresses or swaps an idle helper's weights, and the next dictation
/// then waits 8-22 s for its first text while they page back in (LVX-88, measured on
/// an 8 GB Mac). MLX's wired limit, a Metal residency set, did not prevent that;
/// `mlock` wires the pages in the virtual memory system itself.
enum WeightPageLock {
    struct Report {
        var lockedBytes = 0
        var failedBytes = 0
        /// errno of the first failed `mlock`, 0 when none failed.
        var firstError: Int32 = 0

        var logLine: String {
            "speechd: \(lockedBytes / 1_048_576) MB of weights locked in memory"
                + (failedBytes > 0
                    ? ", \(failedBytes / 1_048_576) MB not (\(String(cString: strerror(firstError))))"
                    : "")
        }
    }

    /// Materializes every parameter of `module` (weights load lazily) and locks the
    /// pages backing it.
    static func lock(_ module: Module) -> Report {
        var report = Report()
        for (_, array) in module.parameters().flattened() {
            // `.noCopy` evaluates the array and wraps its own backing store, which the
            // module keeps alive, so the range locked is the one the GPU reads.
            let backing = array.asData(access: .noCopy).data
            backing.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count > 0 else { return }
                if mlock(base, raw.count) == 0 {
                    report.lockedBytes += raw.count
                } else {
                    report.failedBytes += raw.count
                    if report.firstError == 0 { report.firstError = errno }
                }
            }
        }
        return report
    }
}
