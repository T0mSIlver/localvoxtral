import Foundation

/// What an authenticated hook said about its own plugin version.
///
/// Three states matter downstream and they are NOT the same two collapsed
/// into one (field finding 2026-09-17): a hook that authenticated and sent a
/// valid version header, a hook that authenticated and sent NO valid version
/// header (a plugin from before the header existed — ≤ 1.9.0, which is the
/// outdated case), and a host this process has never heard from (no state at
/// all, represented by the ABSENCE of this type, never by a case).
///
/// Like every `X-Lvx-Env-*` value this is an untrusted label another machine
/// wrote. It is never merged into session or process identity, never logged,
/// and never rendered: it only selects fixed UI strings in Settings.
///
/// The type is `Comparable`, and the order is load-bearing: Claude Code
/// applies a plugin update only on session restart, so after "Update Plugin…"
/// succeeds a host's ALREADY-RUNNING sessions keep executing the OLD plugin's
/// shim — and their hooks keep arriving header-less. A record that could be
/// lowered would let those stale hooks flip a verified host back to
/// "Plugin update available" (the 2026-09-17 follow-up defect), so consumers
/// keep the HIGHEST report seen this app session:
/// `.headerAbsent` < `.version(a)` < `.version(b)` when a is numerically
/// older than b.
public enum ClaudeRemotePluginVersionReport: Sendable, Equatable, Comparable {
    /// The request authenticated but carried no version header that passed
    /// validation. A plugin generation from before the header existed
    /// (≤ 1.9.0) sends exactly this, so it reads as outdated — which it is.
    /// It is the FLOOR of the order: real versions outrank it, because a
    /// version-carrying hook proves more than a silent one.
    case headerAbsent
    /// The request carried this exact, strict-shape version.
    case version(String)

    public static func < (
        lhs: ClaudeRemotePluginVersionReport,
        rhs: ClaudeRemotePluginVersionReport
    ) -> Bool {
        switch (lhs, rhs) {
        case (.headerAbsent, .headerAbsent):
            return false
        case (.headerAbsent, .version):
            return true
        case (.version, .headerAbsent):
            return false
        case (.version(let older), .version(let newer)):
            return ClaudeRemotePluginVersionCodec.isVersion(older, olderThan: newer)
        }
    }
}

/// Reads and validates the shim's `X-Lvx-Plugin-Version` request header.
///
/// The receiving half of a contract whose sending half is a literal line in
/// the shim's private header file (`post.sh`): the value is a constant there,
/// and it is validated HERE before anything looks at it — the same posture
/// `ClaudeRemoteEnvironmentCodec` takes toward the env headers. A value that
/// fails the shape is indistinguishable from a header that was never sent,
/// because a plugin version is a fact the app compares, not text it echoes:
/// nothing downstream may ever see an unvalidated value.
public enum ClaudeRemotePluginVersionCodec {
    /// The header the shim writes, in its canonical spelling.
    public static let headerName = "X-Lvx-Plugin-Version"

    /// How the parser keys it — `ClaudeRemoteHTTPCodec` lowercases field names.
    public static var lowercasedHeaderName: String { headerName.lowercased() }

    /// Strict semantic-version shape: exactly three components, each 1–4
    /// ASCII digits (`^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$`).
    ///
    /// Byte-level, not `Character`-level, for the same reason the env codec
    /// checks bytes: the value arrived over the wire as bytes and the HTTP
    /// head parser already stripped exactly SP/HTAB around it, so any byte
    /// outside `[0-9.]` is a malformed value and not whitespace to forgive.
    public static func isAcceptableVersion(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return false }
        for component in components {
            let bytes = Array(component.utf8)
            guard (1...4).contains(bytes.count) else { return false }
            guard bytes.allSatisfy({ byte in
                byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
            }) else { return false }
        }
        return true
    }

    /// The report a request's headers make about the sender's plugin version.
    ///
    /// Absent and malformed are the SAME answer on purpose: both mean "a
    /// plugin that cannot state its version", which is exactly the ≤ 1.9.0
    /// generation this exists to surface. A value that cannot be compared
    /// must never be recorded as comparable.
    public static func report(in headers: [String: String]) -> ClaudeRemotePluginVersionReport {
        guard let value = headers[lowercasedHeaderName],
              isAcceptableVersion(value)
        else { return .headerAbsent }
        return .version(value)
    }

    /// Numeric comparison, component by component: 1.9.0 vs 1.10.0 must
    /// compare 9 < 10, not `"9" < "10"` as text. Anything that is not exactly
    /// three non-negative numeric components answers false (not older): the
    /// expected side is pinned to the manifest by a tier-0 test and the
    /// reported side is strict-shape-validated before it is ever recorded, so
    /// an unparseable pair is a build bug — and the conservative reading of
    /// one is "do not tell the user to update".
    ///
    /// The ONE implementation of this comparison, shared by the host
    /// registry's monotone record (`Comparable` above) and the Settings
    /// model's outdated verdict, so the two can never disagree about whether
    /// one version is older than another.
    public static func isVersion(_ version: String, olderThan expected: String) -> Bool {
        func components(_ value: String) -> [Int]? {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            var numbers: [Int] = []
            for part in parts {
                guard let number = Int(part), number >= 0 else { return nil }
                numbers.append(number)
            }
            return numbers
        }
        guard let reported = components(version), let current = components(expected) else {
            return false
        }
        for (reportedComponent, currentComponent) in zip(reported, current) {
            if reportedComponent != currentComponent {
                return reportedComponent < currentComponent
            }
        }
        return false
    }
}
