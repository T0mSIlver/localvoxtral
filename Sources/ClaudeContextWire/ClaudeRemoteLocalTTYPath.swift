import Foundation

/// The shape of a terminal device path, applied to `$LC_LVX_TTY` on arrival.
///
/// **This validates a SHAPE, and buys nothing else.** The value is a string a
/// remote host wrote; what makes it usable is not this check but the arm that
/// consumes it — it must equal the tty the app read off the focused terminal
/// through the terminal's own scripting interface, on a surface whose ssh goes
/// to the very host the session authenticated from. A malformed value is
/// refused here so that nothing downstream has to wonder whether a comparison
/// against `""`, a relative path, or a 200-byte string means anything.
///
/// Deliberately not a regex over one platform's naming. The app runs on macOS,
/// so the value it will actually compare is `/dev/ttysNNN`; but the rule that
/// matters is "an absolute path under `/dev` with no traversal", which is what
/// keeps a value from ever looking like anything else if a future caller is
/// careless with it. Equality against the surface's own tty is the real gate.
public enum ClaudeRemoteLocalTTYPath {
    /// `/dev/` plus a device name. Real ones are far shorter; this only has to
    /// exclude a value that is not a device path at all.
    public static let maxLength = 64

    /// Accepted: `/dev/ttys003` (macOS), `/dev/pts/19` (Linux), `/dev/ttyp0`.
    ///
    /// `/dev/tty` is REFUSED although it is a real path: it is the per-process
    /// controlling-terminal alias, so it names no particular window. It could
    /// never equal a terminal's own reported device today, but it is the one
    /// otherwise-plausible value that is ambiguous by construction, and a
    /// future caller comparing it against a hook-reported device would match
    /// everything (review, 2026-09-06).
    ///
    /// Refused: anything not under `/dev/`, an empty device name, a trailing
    /// slash, `.` or `..` anywhere, more than one `/` inside the device name
    /// (so `/dev/a/b/c` is not a tty), and any character outside ASCII
    /// alphanumerics plus `/` — the env-header charset is wider than that, and
    /// a tty name has no business using the rest of it.
    public static func isAcceptable(_ value: String) -> Bool {
        let prefix = "/dev/"
        guard value.hasPrefix(prefix), value.utf8.count <= maxLength else { return false }
        let device = value.dropFirst(prefix.count)
        guard !device.isEmpty, !device.hasSuffix("/") else { return false }
        guard device != "tty" else { return false }
        let segments = device.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(segments.count) else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }
}
