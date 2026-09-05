#if LOCALVOXTRAL_DOGFOOD

import Foundation

/// The wire the dogfood control socket speaks, with no socket and no app in it.
///
/// Split out so the whole grammar — what a client may say, what it gets back,
/// and which characters may appear in either direction — is testable without a
/// descriptor. The socket file below owns bytes and credentials; this file owns
/// meaning.
///
/// ## The format
///
/// Request: ONE line, LF-terminated, at most `maxRequestBytes`, printable
/// ASCII, tokens separated by single spaces. Response: ONE line of JSON, LF
/// terminated, then the server closes. No framing, no length prefix, no
/// session: a debugging client is `nc -U`, and anything richer would be a
/// protocol to maintain rather than a question to ask.
///
/// ## What may cross
///
/// Every value in every reply is drawn from a CLOSED vocabulary — enum case
/// names, booleans and counts. There is no field into which a workspace path,
/// a marker, a nonce, a host, a tty, a pane id, a session id or a transcript
/// can be written, because no reply field is ever built from one. That is a
/// property of the renderers below, and `DogfoodControlServiceTests` asserts it
/// field by field against a registry snapshot full of identifiers.
enum DogfoodControlProtocol {
    /// A request longer than this is refused unread past the cap. Every legal
    /// command is under 25 bytes; the slack is for a clearer error than a
    /// truncated line would give.
    static let maxRequestBytes = 256

    /// Every command this socket understands. Adding a case here is adding a
    /// capability to a debug surface — see the file header of
    /// `DogfoodControlSocket.swift` before doing it.
    enum Command: Equatable {
        /// Run a dictation through the real trigger path.
        case sessionStart(DictationOutputMode)
        /// End the dictation this socket (or the user) started.
        case sessionStop
        /// The join the LAST dictation resolved, from the live registry.
        case joinReport
        /// Resolve the focused surface NOW, against the live registry.
        case surfaceProbe
        /// The live sessions the app knows about.
        case registryList

        /// The canonical spelling, echoed back so a client reading a reply out
        /// of a log knows what produced it.
        var wireName: String {
            switch self {
            case .sessionStart(.overlayBuffer): return "session start overlay"
            case .sessionStart(.liveAutoPaste): return "session start live"
            case .sessionStop: return "session stop"
            case .joinReport: return "join report"
            case .surfaceProbe: return "surface probe"
            case .registryList: return "registry list"
            }
        }
    }

    /// Why a line was not a command. Never quotes the line back: a rejected
    /// request is attacker-chosen text as far as this code is concerned, and
    /// echoing it into a reply (which an agent pastes into a PR) is the same
    /// log-injection shape the UI gate's `log_command` guards against.
    enum RequestError: String, Error, Equatable {
        case empty = "empty request"
        case tooLong = "request exceeds the byte cap"
        case nonPrintable = "request contains a non-printable byte"
        case unknownCommand = "unknown command"
        case badArgument = "unrecognized argument"
        case missingArgument = "command needs an argument"
        case extraArgument = "command takes no further arguments"
    }

    /// Parse one already-de-framed line.
    ///
    /// Total: every rejection is one of the cases above, so the socket never
    /// has to invent an error string at the call site.
    static func parse(request line: String) -> Result<Command, RequestError> {
        guard line.utf8.count <= maxRequestBytes else { return .failure(.tooLong) }
        // ASCII printable only. A control byte cannot appear in any legal
        // command, and refusing it here means no downstream renderer has to
        // wonder whether an echoed token could contain a newline.
        guard line.allSatisfy({ $0.isASCII && ($0 == " " || !$0.isNewline) }) else {
            return .failure(.nonPrintable)
        }
        guard line.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else {
            return .failure(.nonPrintable)
        }
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let verb = tokens.first else { return .failure(.empty) }
        let rest = Array(tokens.dropFirst())

        switch verb {
        case "session":
            guard let sub = rest.first else { return .failure(.missingArgument) }
            switch sub {
            case "start":
                let modeTokens = Array(rest.dropFirst())
                guard modeTokens.count <= 1 else { return .failure(.extraArgument) }
                // Defaulting the mode would make `session start` mean
                // "whatever the owner's settings say today", and the two modes
                // take DIFFERENT paths through insertion. A debug verb must
                // name what it is exercising.
                guard let modeToken = modeTokens.first else { return .failure(.missingArgument) }
                switch modeToken {
                case "overlay": return .success(.sessionStart(.overlayBuffer))
                case "live": return .success(.sessionStart(.liveAutoPaste))
                default: return .failure(.badArgument)
                }
            case "stop":
                guard rest.count == 1 else { return .failure(.extraArgument) }
                return .success(.sessionStop)
            default:
                return .failure(.badArgument)
            }
        case "join":
            guard rest == ["report"] else {
                return .failure(rest.isEmpty ? .missingArgument : .badArgument)
            }
            return .success(.joinReport)
        case "surface":
            guard rest == ["probe"] else {
                return .failure(rest.isEmpty ? .missingArgument : .badArgument)
            }
            return .success(.surfaceProbe)
        case "registry":
            guard rest == ["list"] else {
                return .failure(rest.isEmpty ? .missingArgument : .badArgument)
            }
            return .success(.registryList)
        default:
            return .failure(.unknownCommand)
        }
    }

    /// The reply envelope. Keys always in this order, nulls always present —
    /// the same rule, for the same reason, as `ClaudeSessionJoinSummary.jsonLine`:
    /// a synthesized encoder drops nil optionals and turns "no result" into
    /// "this build has no such field".
    static func reply(command: Command?, result: String?, error: String?) -> String {
        DogfoodControlJSON.object([
            ("ok", DogfoodControlJSON.bool(error == nil)),
            ("command", command.map { DogfoodControlJSON.string($0.wireName) } ?? "null"),
            ("error", error.map(DogfoodControlJSON.string) ?? "null"),
            ("result", result ?? "null"),
        ])
    }
}

/// Ordered JSON rendering.
///
/// Hand-rendered rather than `JSONEncoder`-ed for the reason
/// `ClaudeSessionJoinSummary` gives: the key order and the presence of nulls
/// ARE the contract a shell client asserts against. Escaping still goes through
/// `JSONSerialization`, so a future enum case carrying a quote cannot emit
/// invalid JSON.
enum DogfoodControlJSON {
    static func object(_ fields: [(String, String)]) -> String {
        "{" + fields.map { "\(string($0.0)):\($0.1)" }.joined(separator: ",") + "}"
    }

    static func array(_ elements: [String]) -> String {
        "[" + elements.joined(separator: ",") + "]"
    }

    static func string(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
              let rendered = String(data: data, encoding: .utf8),
              rendered.count >= 2
        else { return "\"\"" }
        return String(rendered.dropFirst().dropLast())
    }

    static func bool(_ value: Bool) -> String { value ? "true" : "false" }

    static func int(_ value: Int) -> String { String(value) }

    static func optionalString(_ value: String?) -> String {
        value.map(string) ?? "null"
    }

    static func optionalBool(_ value: Bool?) -> String {
        value.map(bool) ?? "null"
    }
}

#endif
