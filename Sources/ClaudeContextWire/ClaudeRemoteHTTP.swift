import Foundation

/// The HTTP contract between a REMOTE Claude Code session and the app's
/// loopback listener.
///
/// The remote plugin's command hooks run its bundled POSIX-sh shim, which curls
/// the hook event JSON here and prints our response JSON back for Claude Code.
/// There is no publisher binary on the remote host and nothing for the user to
/// install beyond the plugin — the shim needs only `sh` and `curl`. (It cannot
/// be a declarative `type: "http"` hook: Claude Code never injects plugin
/// userConfig options into http-hook header expansion, so an http hook can
/// never present the bearer token — verified on 2.1.220.)
///
/// This type is Foundation-only for the same reason the rest of the module is:
/// the contract must be checkable without a socket, and the parser is the piece
/// most worth testing against hostile bytes.
///
/// Why hand-rolled rather than `Network.framework`/`URLSession`: the listener
/// this feeds has to bind loopback ONLY, read the `Authorization` header before
/// it will retain a body, and hard-cap head/body/connection lifetime. NWListener
/// gives us an HTTP-shaped abstraction that hides exactly those decisions. A
/// bounded POSIX parser is the smaller risk — and it is the same trade the local
/// AF_UNIX broker already made for peer credentials.
public struct ClaudeRemoteHTTPLimits: Sendable, Equatable {
    /// Max bytes of request line + headers. A head longer than this is not a
    /// request we want to understand.
    public var maxHeadBytes: Int
    /// Max `Content-Length` we will accept, and therefore the most a peer can
    /// ever make us buffer.
    public var maxBodyBytes: Int
    /// Max distinct header fields.
    public var maxHeaderCount: Int
    /// Max bytes of the `Authorization` value. A token is ~43 base64url
    /// characters; anything approaching this is not a token.
    public var maxTokenBytes: Int

    public init(
        maxHeadBytes: Int = 8 * 1024,
        maxBodyBytes: Int = 64 * 1024,
        maxHeaderCount: Int = 64,
        maxTokenBytes: Int = 512
    ) {
        self.maxHeadBytes = maxHeadBytes
        self.maxBodyBytes = maxBodyBytes
        self.maxHeaderCount = maxHeaderCount
        self.maxTokenBytes = maxTokenBytes
    }

    public static let `default` = ClaudeRemoteHTTPLimits()
}

/// What a request's `Authorization` header turned out to be.
///
/// Carries the credential in `.bearer` and NOTHING derived from it in the other
/// cases — no length, no prefix, no digest. A diagnostic that narrows a secret
/// is not a diagnostic worth having.
public enum ClaudeRemoteAuthorizationShape: Sendable, Equatable {
    /// No `Authorization` header, or a `Bearer` scheme with an empty credential.
    case missing
    /// Present, but not a `Bearer` credential we are willing to read.
    case malformed
    case bearer(String)
}

/// A parsed request head. The body is deliberately NOT part of this type: the
/// listener authenticates on the head alone and only then reads bytes.
public struct ClaudeRemoteHTTPRequest: Sendable, Equatable {
    public var method: String
    /// Path with any query string removed.
    public var path: String
    /// Field names lowercased. Duplicates are a parse error, not a merge.
    public var headers: [String: String]
    public var contentLength: Int
    /// The `Bearer` credential, when the header carried a well-formed one.
    public var bearerToken: String?

    public init(
        method: String,
        path: String,
        headers: [String: String],
        contentLength: Int,
        bearerToken: String?
    ) {
        self.method = method
        self.path = path
        self.headers = headers
        self.contentLength = contentLength
        self.bearerToken = bearerToken
    }
}

public enum ClaudeRemoteHTTPError: Error, Equatable {
    /// The head is not complete yet — read more and retry. Only meaningful
    /// while still under `maxHeadBytes`.
    case incompleteHead
    case headTooLarge
    case malformed
    case unsupportedMethod(String)
    /// Chunked (or any) transfer coding. We require a `Content-Length` so the
    /// body bound is known BEFORE a byte of it is read; a chunked body's size is
    /// only knowable by reading it, which is precisely the thing we refuse.
    case unsupportedTransferEncoding
    case lengthRequired
    case bodyTooLarge(Int)
}

public enum ClaudeRemoteHTTPCodec {
    /// URL path prefix. The event name is the last component, which gives the
    /// parser a fallback when a payload omits `hook_event_name`.
    public static let hookPathPrefix = "/v1/hook/"

    /// CRLFCRLF. Public because it is not merely this parser's business: it
    /// occupies the same read buffer as the head and the body, so anything
    /// sizing that buffer has to account for it too.
    public static let headTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    /// Parse a request head out of `buffer`.
    ///
    /// - Returns: the request, and the offset (relative to `buffer.startIndex`)
    ///   at which the body begins.
    /// - Throws: `.incompleteHead` when more bytes are needed. Every other error
    ///   is terminal for the connection.
    public static func parseRequestHead(
        _ buffer: Data,
        limits: ClaudeRemoteHTTPLimits = .default
    ) throws -> (request: ClaudeRemoteHTTPRequest, bodyOffset: Int) {
        guard let terminator = buffer.range(of: headTerminator) else {
            // Bound the incomplete case too: a peer that opens a connection and
            // streams headers forever must not grow our buffer without limit.
            if buffer.count > limits.maxHeadBytes { throw ClaudeRemoteHTTPError.headTooLarge }
            throw ClaudeRemoteHTTPError.incompleteHead
        }
        let headLength = terminator.lowerBound - buffer.startIndex
        guard headLength <= limits.maxHeadBytes else { throw ClaudeRemoteHTTPError.headTooLarge }

        let headData = Data(buffer[buffer.startIndex..<terminator.lowerBound])
        guard let head = String(data: headData, encoding: .utf8) else {
            throw ClaudeRemoteHTTPError.malformed
        }

        // CRLF only. Tolerating bare LF would mean two parsers could disagree
        // about where a header ends, which is the shape of every request
        // smuggling bug ever written.
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw ClaudeRemoteHTTPError.malformed }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { throw ClaudeRemoteHTTPError.malformed }
        let method = parts[0]
        let target = parts[1]
        let version = parts[2]
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            throw ClaudeRemoteHTTPError.malformed
        }
        guard method == "POST" else { throw ClaudeRemoteHTTPError.unsupportedMethod(method) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard headers.count < limits.maxHeaderCount else { throw ClaudeRemoteHTTPError.malformed }
            guard let colon = line.firstIndex(of: ":") else {
                // Also catches obs-fold continuation lines (` value`), which we
                // will not reassemble.
                throw ClaudeRemoteHTTPError.malformed
            }
            let name = trimmingOWS(line[line.startIndex..<colon]).lowercased()
            let value = trimmingOWS(line[line.index(after: colon)...])
            guard !name.isEmpty else { throw ClaudeRemoteHTTPError.malformed }
            // Duplicates are rejected rather than last-wins. Two Content-Lengths
            // or two Authorizations mean the sender and we would have to agree on
            // a tie-break rule; refusing needs no rule.
            guard headers[name] == nil else { throw ClaudeRemoteHTTPError.malformed }
            headers[name] = value
        }

        guard headers["transfer-encoding"] == nil else {
            throw ClaudeRemoteHTTPError.unsupportedTransferEncoding
        }
        guard let lengthValue = headers["content-length"] else {
            throw ClaudeRemoteHTTPError.lengthRequired
        }
        // Digits only: `Int("+5")` is 5, and a length the peer writes differently
        // from how we read it is a body we would mis-frame.
        guard !lengthValue.isEmpty,
              lengthValue.allSatisfy({ $0.isASCII && $0.isNumber }),
              let contentLength = Int(lengthValue)
        else {
            throw ClaudeRemoteHTTPError.malformed
        }
        guard contentLength <= limits.maxBodyBytes else {
            throw ClaudeRemoteHTTPError.bodyTooLarge(contentLength)
        }

        let path = String(
            target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        )
        let request = ClaudeRemoteHTTPRequest(
            method: method,
            path: path,
            headers: headers,
            contentLength: contentLength,
            bearerToken: bearerToken(in: headers["authorization"], limits: limits)
        )
        return (request, terminator.upperBound - buffer.startIndex)
    }

    /// Strip HTTP optional whitespace — ASCII SP and HTAB, and nothing else.
    ///
    /// NOT `trimmingCharacters(in: .whitespaces)`, which is a UNICODE set: it
    /// eats U+00A0 NBSP, U+2007, U+3000 and friends. Two bugs follow from that,
    /// and only the second is obvious:
    ///
    /// 1. It rewrites the field NAME. `Content-Length<NBSP>: 5` would trim to
    ///    `content-length` here while a conforming proxy reads a different (or
    ///    invalid) header — the parsers-disagree shape this file exists to
    ///    avoid.
    /// 2. It launders a field VALUE past a byte-level validator. The env
    ///    enrichment rejects any non-ASCII byte, but `pane-7<NBSP>` was being
    ///    trimmed to `pane-7` BEFORE that check ever ran, so a malformed wire
    ///    value was accepted as a well-formed one.
    ///
    /// RFC 9110 defines OWS as `*( SP / HTAB )`. Trimming exactly that means a
    /// value's bytes reach a validator as the peer actually wrote them.
    static func trimmingOWS(_ value: Substring) -> String {
        var slice = value
        while let first = slice.first, first == " " || first == "\t" {
            slice = slice.dropFirst()
        }
        while let last = slice.last, last == " " || last == "\t" {
            slice = slice.dropLast()
        }
        return String(slice)
    }

    /// The `Bearer` credential, or nil for any other scheme/shape.
    public static func bearerToken(
        in headerValue: String?,
        limits: ClaudeRemoteHTTPLimits = .default
    ) -> String? {
        guard case .bearer(let token) = authorizationShape(in: headerValue, limits: limits) else {
            return nil
        }
        return token
    }

    /// WHY an `Authorization` header did not yield a credential — the same walk
    /// as `bearerToken`, keeping its answer instead of collapsing every failure
    /// to nil.
    ///
    /// The distinction is not cosmetic. A remote host on a pre-1.1.0 plugin sends
    /// `Authorization: Bearer ` with nothing after it (the http hook could never
    /// present the token), and a host whose token was rotated sends a perfectly
    /// well-formed one that no longer matches. Both used to log the same line, so
    /// hours of rejections said nothing about which of the two fixes — update the
    /// plugin, or re-run enrollment — the user actually needed.
    ///
    /// It classifies SHAPE only. The credential is returned for the caller to
    /// authenticate; nothing here measures, hashes, or reports it.
    public static func authorizationShape(
        in headerValue: String?,
        limits: ClaudeRemoteHTTPLimits = .default
    ) -> ClaudeRemoteAuthorizationShape {
        guard let headerValue else { return .missing }
        // Oversized before anything else: a header this long is not a credential
        // we failed to read, it is a header we refuse to read.
        guard headerValue.utf8.count <= limits.maxTokenBytes else { return .malformed }
        let parts = headerValue.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let scheme = parts.first else { return .missing }
        guard scheme.lowercased() == "bearer" else { return .malformed }
        // `Bearer` with an empty credential — including the header parser's
        // already-trimmed `Bearer ` — is the pre-1.1.0 plugin's exact shape, and
        // is reported as a missing token rather than a malformed header.
        guard parts.count == 2 else { return .missing }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? .missing : .bearer(token)
    }

    /// The event name a hook URL carries, e.g. `/v1/hook/SessionStart`.
    ///
    /// This is a FALLBACK for a payload with no `hook_event_name`, never an
    /// override: a URL is chosen by the plugin manifest, and the payload is the
    /// thing Claude Code actually did.
    public static func eventName(inPath path: String) -> String? {
        guard path.hasPrefix(hookPathPrefix) else { return nil }
        let name = String(path.dropFirst(hookPathPrefix.count))
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return name
    }

    /// Serialize a response. Always `Connection: close` — one request per
    /// connection means a peer can never keep a slot alive by going quiet
    /// between requests.
    public static func response(status: Int, body: Data? = nil) -> Data {
        var head = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
        head += "Connection: close\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body?.count ?? 0)\r\n"
        if status == 401 { head += "WWW-Authenticate: Bearer\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }

    /// The ONLY body shape this listener ever returns.
    ///
    /// `ClaudeHookOutput` has exactly two properties, so the response key
    /// allowlist (`terminalSequence`, `suppressOutput`) is a property of the
    /// type rather than of a filter someone has to remember to apply. Claude
    /// Code executes what it finds here — an extra key would at best be ignored
    /// and at worst be a control channel we did not mean to open.
    public static func markerResponseBody(marker: String?) -> Data {
        if let line = ClaudeHookOutput.markerOutputLine(marker: marker) { return line }
        // No marker, or a marker we are not willing to emit: still answer, but
        // with nothing for the terminal to execute.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(ClaudeHookOutput(terminalSequence: nil))) ?? Data("{}".utf8)
    }

    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        default: return "Error"
        }
    }
}

/// Who is allowed to reach the remote listener at the transport level.
///
/// Pure and Foundation-only so the decision is unit-testable without binding a
/// port — the socket is bound to loopback, and this re-checks the accepted
/// peer's address anyway. Two independent statements of the same rule, because
/// "the port is loopback-bound" is a claim about our own setup code that a
/// future edit could quietly falsify.
public enum ClaudeRemotePeerPolicy {
    /// 127.0.0.0/8, per RFC 1122. The far end of an OpenSSH `RemoteForward`
    /// connects from the local ssh client, which lands here.
    public static func isLoopbackIPv4(hostOrderAddress: UInt32) -> Bool {
        (hostOrderAddress >> 24) == 127
    }
}
