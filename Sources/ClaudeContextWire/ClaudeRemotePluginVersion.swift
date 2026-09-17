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
public enum ClaudeRemotePluginVersionReport: Sendable, Equatable {
    /// The request authenticated but carried no version header that passed
    /// validation. A plugin generation from before the header existed
    /// (≤ 1.9.0) sends exactly this, so it reads as outdated — which it is.
    case headerAbsent
    /// The request carried this exact, strict-shape version.
    case version(String)
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
}
