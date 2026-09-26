import Darwin
import Foundation

/// A process's memory as Activity Monitor's Memory column counts it
/// (`phys_footprint`), read with `proc_pid_rusage`. Works on the app's own
/// children without any entitlement.
enum ProcessMemory {
    static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard status == 0 else { return nil }
        return info.ri_phys_footprint
    }
}
