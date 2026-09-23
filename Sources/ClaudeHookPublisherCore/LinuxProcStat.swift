import Foundation

/// What the hook reads about a process on Linux, where there is no
/// `sysctl(KERN_PROC_PID)`: the fields of `/proc/<pid>/stat` (proc(5)) that
/// the Darwin path takes from `kinfo_proc`.
///
/// Parsing is pure so the Mac suite covers it; only the file reads are
/// Linux-only.
struct LinuxProcStat: Equatable {
    var pid: Int32
    var parent: Int32
    var session: Int32
    /// `tty_nr`: the controlling terminal's device number, 0 when none.
    var ttyNumber: Int64
    /// Clock ticks from boot to the process start.
    var startTicks: UInt64

    /// Parses one `/proc/<pid>/stat` line. Field 2 is the command name in
    /// parentheses, and a name can hold spaces and `)`, so the fixed fields
    /// start after the LAST `)`.
    static func parse(_ line: String) -> LinuxProcStat? {
        guard let open = line.firstIndex(of: "("),
              let close = line.lastIndex(of: ")"),
              open < close,
              let pid = Int32(line[..<open].trimmingCharacters(in: .whitespaces))
        else { return nil }
        // After the name: state(3) ppid(4) pgrp(5) session(6) tty_nr(7)
        // ... starttime(22), so index = field number - 3.
        let fields = line[line.index(after: close)...].split(separator: " ")
        guard fields.count > 19,
              let parent = Int32(fields[1]),
              let session = Int32(fields[3]),
              let ttyNumber = Int64(fields[4]),
              let startTicks = UInt64(fields[19])
        else { return nil }
        return LinuxProcStat(
            pid: pid,
            parent: parent,
            session: session,
            ttyNumber: ttyNumber,
            startTicks: startTicks
        )
    }

    /// The `/dev/pts/N` path `tty_nr` encodes, or nil for no terminal or one
    /// that is not a pseudo-terminal. Only a pty can back a terminal pane,
    /// which is the only device the focus join can match (the same reason
    /// `ClaudeRemoteLocalTTYPath` refuses aliases).
    ///
    /// The kernel encodes `tty_nr` as major in bits 8–19, minor in bits 0–7
    /// and 20–31. Pty slaves are major 136 with the pts index as the minor.
    static func ptsPath(ttyNumber: Int64) -> String? {
        guard ttyNumber > 0 else { return nil }
        let major = (ttyNumber >> 8) & 0xfff
        let minor = (ttyNumber & 0xff) | ((ttyNumber >> 12) & 0xfff00)
        guard major == 136 else { return nil }
        return "/dev/pts/\(minor)"
    }

    /// Boot time in seconds since the epoch: the `btime` line of `/proc/stat`.
    static func bootTimeSeconds(procStat: String) -> Int64? {
        for line in procStat.split(separator: "\n") where line.hasPrefix("btime ") {
            return Int64(line.dropFirst("btime ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Process start in microseconds since the epoch, the unit
    /// `ProcessFacts.startMicros` carries on Darwin.
    static func startMicros(startTicks: UInt64, bootTimeSeconds: Int64, ticksPerSecond: Int64) -> Int64? {
        guard ticksPerSecond > 0, bootTimeSeconds > 0,
              startTicks <= UInt64(Int64.max / 1_000_000)
        else { return nil }
        let sinceBoot = Int64(startTicks) * 1_000_000 / ticksPerSecond
        return bootTimeSeconds * 1_000_000 + sinceBoot
    }

    #if os(Linux)
    /// Reads and parses `/proc/<pid>/stat`, nil when the process is gone or
    /// the file is unreadable.
    static func read(pid: Int32) -> LinuxProcStat? {
        guard pid > 0,
              let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let stat = parse(text),
              stat.pid == pid
        else { return nil }
        return stat
    }

    static func readBootTimeSeconds() -> Int64? {
        guard let text = try? String(contentsOfFile: "/proc/stat", encoding: .utf8) else { return nil }
        return bootTimeSeconds(procStat: text)
    }
    #endif
}
