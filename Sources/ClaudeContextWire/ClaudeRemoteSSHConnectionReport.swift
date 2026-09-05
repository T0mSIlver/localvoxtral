import Foundation

/// A remote session's report of the ssh connection it is running inside:
/// `$SSH_CONNECTION`, which sshd sets in every session it spawns as
/// `"<client-ip> <client-port> <server-ip> <server-port>"`.
///
/// Measured, not assumed (dev box, OpenSSH 9.x, 2026-09-05): a client whose
/// established socket was `127.0.0.1:43234 -> 127.0.0.1:2222` saw
/// `SSH_CONNECTION=[127.0.0.1 43234 127.0.0.1 2222]` inside the session. The
/// client port is the ephemeral port the CLIENT's kernel picked, so it is a
/// value only the two kernels on the ends of that one connection know — which
/// is the whole reason this type exists.
///
/// **Still untrusted.** Like every other field of
/// `ClaudeRemoteSessionEnvironment` this is a string a remote host wrote. It is
/// never an address to dial, resolve, or connect to; the only thing the app
/// does with it is compare it, byte for byte after parsing, against a socket
/// the app read out of its OWN kernel. Parsing here buys shape, not truth.
///
/// The value arrives with COMMAS where sshd wrote spaces: space is outside the
/// env-header charset (`ClaudeRemoteEnvironmentCodec.isAllowedByte`, the whole
/// header-injection defence), so the shim re-joins the four fields before it
/// writes the header. Widening that charset for one field was the alternative
/// and was refused — a value that cannot contain a space cannot end a header
/// line, and that property is worth more than a cosmetic wire format.
public struct ClaudeRemoteSSHConnectionReport: Sendable, Equatable {
    /// The address the SERVER saw the client connect from. Recorded for
    /// diagnostics and completeness; the local end of the connection is behind
    /// whatever NAT sits in between, so nothing compares against it.
    public let clientAddress: String
    /// The client's ephemeral source port — the field with the entropy.
    public let clientPort: UInt16
    /// The address the client connected TO, as the server names it.
    public let serverAddress: String
    /// The port the client connected to (22 in the ordinary case).
    public let serverPort: UInt16

    public init(
        clientAddress: String,
        clientPort: UInt16,
        serverAddress: String,
        serverPort: UInt16
    ) {
        self.clientAddress = clientAddress
        self.clientPort = clientPort
        self.serverAddress = serverAddress
        self.serverPort = serverPort
    }

    /// The separator the shim writes in place of sshd's spaces.
    public static let fieldSeparator: Character = ","

    /// Longest textual IPv6 form, `inet_ntop`'s own `INET6_ADDRSTRLEN` minus
    /// its NUL. Anything longer is not an address this app will ever compare.
    public static let maxAddressLength = 45

    /// Parse the normalized value, or nil for ANY shape that is not exactly
    /// four fields of the expected kind.
    ///
    /// Deliberately lexical: an address is accepted here when it is made of
    /// hex digits, `.` and `:` within the length bound — the shape sshd emits —
    /// and NOT resolved into a network address. Turning the text into bytes is
    /// the local comparison's job (`SSHConnectionAddressMatch`), where a failure
    /// to parse abstains from the join. Splitting it that way keeps libc, and
    /// the question "what is this address", out of the wire module entirely.
    ///
    /// Rejected on purpose: leading `+`/`-`/zeros on a port (a port is a
    /// canonical decimal number or it is not one), port 0, empty fields, more
    /// or fewer than four fields, and any byte outside the address charset —
    /// including the `%` of an IPv6 zone id, which no comparison here could
    /// honour anyway.
    public static func parse(_ value: String) -> ClaudeRemoteSSHConnectionReport? {
        // Four fields exactly. `omittingEmptySubsequences: false` so `a,,b,c`
        // is a four-field value with an empty field — refused below — rather
        // than a three-field one.
        let fields = value.split(
            separator: fieldSeparator, omittingEmptySubsequences: false
        )
        guard fields.count == 4 else { return nil }
        guard let clientAddress = address(fields[0]),
              let clientPort = port(fields[1]),
              let serverAddress = address(fields[2]),
              let serverPort = port(fields[3])
        else { return nil }
        return ClaudeRemoteSSHConnectionReport(
            clientAddress: clientAddress,
            clientPort: clientPort,
            serverAddress: serverAddress,
            serverPort: serverPort
        )
    }

    private static func address(_ field: Substring) -> String? {
        guard !field.isEmpty, field.utf8.count <= maxAddressLength else { return nil }
        let allowed = field.allSatisfy { character in
            character.isASCII
                && (character.isHexDigit || character == "." || character == ":")
        }
        return allowed ? String(field) : nil
    }

    private static func port(_ field: Substring) -> UInt16? {
        // At most five digits so the conversion below can never see an
        // oversized literal, no leading zero so there is exactly one spelling
        // of every port, and never 0 — sshd cannot report an unbound socket.
        guard (1...5).contains(field.count),
              field.allSatisfy({ $0.isASCII && $0.isNumber }),
              field.first != "0",
              let port = UInt16(field), port > 0
        else { return nil }
        return port
    }
}
