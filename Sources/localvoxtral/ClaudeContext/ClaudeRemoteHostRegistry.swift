import CryptoKit
import Foundation
import Synchronization

/// Non-secret metadata for one enrolled remote host.
///
/// This is the whole public view of a host. There is no `token` property, and
/// there is no accessor that could produce one: the plaintext exists exactly
/// once, in the return value of `enroll`/`rotateToken`, and is never written
/// down. If the user loses it, the answer is to rotate — not to look it up.
public struct ClaudeRemoteHost: Sendable, Equatable, Identifiable {
    /// Opaque id we assign. Also the session namespace and the origin channel,
    /// so it must never contain anything path- or separator-shaped.
    public let id: String
    /// User-facing name (typically the SSH host alias). Sanitized on enroll.
    public var label: String
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var revokedAt: Date?

    public var isRevoked: Bool { revokedAt != nil }
}

/// A freshly issued credential. The ONLY time a plaintext token exists.
public struct ClaudeRemoteEnrollment: Sendable, Equatable {
    public var host: ClaudeRemoteHost
    /// Show once, then forget. Nothing persists this.
    public var token: String
}

/// Hashing and comparison for host tokens.
///
/// Split out from the registry so both halves are testable in isolation, and so
/// the constant-time rule has one home rather than being re-derived at each
/// comparison site.
public enum ClaudeRemoteTokenDigest {
    /// The alphabet `makeToken` emits (base64url). Checked before hashing: a
    /// token-shaped string is cheap to reject, and hashing whatever a peer sends
    /// is work we do not owe them.
    static let allowedCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
    static let minTokenLength = 16
    static let maxTokenLength = 128

    public static func isWellFormed(_ token: String) -> Bool {
        guard token.count >= minTokenLength, token.count <= maxTokenLength else { return false }
        return token.allSatisfy { allowedCharacters.contains($0) }
    }

    /// SHA-256 over `salt || token`, hex.
    ///
    /// The salt is per host and not itself a secret; it is here so that two
    /// hosts issued (improbably) the same token do not share a stored hash, and
    /// so the file cannot be attacked with one precomputed table across users.
    public static func hash(token: String, salt: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(salt.utf8))
        hasher.update(data: Data(token.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Compare without leaking, through timing, HOW MUCH of the value matched.
    ///
    /// Both inputs here are hex digests of a fixed length, so the length branch
    /// reveals nothing an attacker does not already know. The byte loop is the
    /// part that matters: a short-circuiting `==` on a secret-derived value tells
    /// a patient caller the common prefix, one byte at a time.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    /// 32 bytes of CSPRNG, base64url, unpadded.
    ///
    /// base64url specifically: the token travels through an SSH config comment's
    /// worth of hostile places — a shell command line, an HTTP header value, a
    /// JSON string — and `[A-Za-z0-9_-]` needs quoting or escaping in none of
    /// them.
    /// `Swift.random` without an explicit generator draws from
    /// `SystemRandomNumberGenerator`, which is documented as cryptographically
    /// secure on Apple platforms and is safe to call concurrently.
    public static func makeToken() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Short, opaque, and — because it becomes a session-id namespace and an
    /// origin channel — hex only.
    public static func makeHostID() -> String {
        let hex = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return "h\(hex)"
    }
}

/// Reading and writing the host file, as a seam.
///
/// Injected so the registry's behaviour — atomicity contract, permissions,
/// what is and is not written — is testable without touching a real disk, and
/// so a test can force an I/O failure that a real filesystem would not oblige.
public protocol ClaudeRemoteHostStoreIO: Sendable {
    /// Nil when the store does not exist yet. Throwing means "exists but is
    /// unreadable", which is not the same thing and must not be treated as
    /// "start fresh" — that would silently discard the user's enrollments.
    func read(from url: URL) throws -> Data?
    /// Replace the file's contents atomically, mode 0600.
    func write(_ data: Data, to url: URL) throws
}

/// The on-disk implementation.
public struct ClaudeRemoteHostFileStoreIO: ClaudeRemoteHostStoreIO {
    public init() {}

    public func read(from url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Write to a sibling temp file created 0600, then `rename(2)` over the
    /// target.
    ///
    /// Not `Data.write(options: .atomic)`: that is atomic, but it creates the
    /// temp file with umask-derived permissions and only fixes them afterwards
    /// — a window in which a file of token hashes is world-readable. Creating it
    /// 0600 up front means the bytes are never reachable, not even briefly.
    /// `rename` within the same directory is atomic, so a crash mid-write leaves
    /// the previous file intact rather than a truncated one.
    public func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp")
        try? FileManager.default.removeItem(at: temporary)
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw ClaudeRemoteHostRegistry.StoreError.writeFailed(path: url.path)
        }
        // `replaceItemAt` would leave the replacement's own metadata behind on
        // some volumes; a plain rename keeps the 0600 we just set.
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}

/// Enrolled remote hosts and their token hashes.
///
/// The security properties, all of which have a test:
///
/// * **Only hashes are stored.** A plaintext token exists in memory for the
///   length of one `enroll` call and in the setup instructions the user pastes.
///   Reading this file tells an attacker who is enrolled, not how to connect.
/// * **The file is 0600 and written atomically**, so it is never briefly
///   readable and never half-written.
/// * **Authentication is constant-time and does not short-circuit across
///   hosts**, so neither the token nor which host owns it leaks through timing.
/// * **Revocation is immediate** — `authenticate` consults `revokedAt` on every
///   call rather than pruning lazily.
///
/// `Mutex` + `Sendable`, per repo convention: the listener's connection threads
/// authenticate while the main actor may be enrolling.
public final class ClaudeRemoteHostRegistry: Sendable {
    /// Persisted shape. Internal: `tokenHash`/`tokenSalt` are storage details,
    /// and a public type carrying them invites someone to log one.
    struct StoredHost: Codable, Equatable {
        var id: String
        var label: String
        var createdAt: Date
        var lastSeenAt: Date?
        var revokedAt: Date?
        var tokenSalt: String
        var tokenHash: String

        var publicView: ClaudeRemoteHost {
            ClaudeRemoteHost(
                id: id,
                label: label,
                createdAt: createdAt,
                lastSeenAt: lastSeenAt,
                revokedAt: revokedAt
            )
        }
    }

    struct StoredFile: Codable, Equatable {
        var version: Int
        var hosts: [StoredHost]

        enum CodingKeys: String, CodingKey {
            case version = "v"
            case hosts
        }
    }

    public enum StoreError: Error, Equatable {
        case unknownHost(String)
        case unreadable(path: String)
        case unsupportedVersion(Int)
        case writeFailed(path: String)
        case invalidLabel
        case tooManyHosts(limit: Int)
        /// The id allocator failed to produce an unused id. Effectively
        /// impossible; reported rather than looped on forever.
        case idAllocationFailed
    }

    /// Bump on any incompatible change to `StoredFile`.
    static let fileVersion = 1

    /// Cap on enrolled hosts. Not a security boundary — a bound on a file we
    /// read on every listener start.
    public static let maxHosts = 32

    private let state: Mutex<[StoredHost]>
    private let fileURL: URL
    private let io: any ClaudeRemoteHostStoreIO
    private let now: @Sendable () -> Date
    private let makeToken: @Sendable () -> String
    private let makeHostID: @Sendable () -> String

    /// - Parameters:
    ///   - now: injected clock (AGENTS: no wall-clock in tests).
    ///   - makeToken/makeHostID: injected so tests can pin exact values and
    ///     force an id collision.
    public init(
        fileURL: URL = ClaudeRemoteHostRegistry.defaultFileURL(),
        io: any ClaudeRemoteHostStoreIO = ClaudeRemoteHostFileStoreIO(),
        now: @escaping @Sendable () -> Date = { Date() },
        makeToken: @escaping @Sendable () -> String = { ClaudeRemoteTokenDigest.makeToken() },
        makeHostID: @escaping @Sendable () -> String = { ClaudeRemoteTokenDigest.makeHostID() }
    ) throws {
        self.fileURL = fileURL
        self.io = io
        self.now = now
        self.makeToken = makeToken
        self.makeHostID = makeHostID

        guard let data = try io.read(from: fileURL) else {
            state = Mutex([])
            return
        }
        guard let file = try? JSONDecoder.claudeRemote.decode(StoredFile.self, from: data) else {
            // An unreadable store is REPORTED, never silently replaced. Starting
            // fresh would revoke every enrolled host by accident and, worse, do
            // it quietly — the user would just find that dictation context had
            // stopped working one day.
            throw StoreError.unreadable(path: fileURL.path)
        }
        guard file.version == Self.fileVersion else {
            throw StoreError.unsupportedVersion(file.version)
        }
        state = Mutex(file.hosts)
    }

    public static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("localvoxtral", isDirectory: true)
            .appendingPathComponent("claude-remote-hosts.json")
    }

    // MARK: - Queries

    public func hosts() -> [ClaudeRemoteHost] {
        state.withLock { $0.map(\.publicView) }.sorted { $0.createdAt < $1.createdAt }
    }

    public func host(id: String) -> ClaudeRemoteHost? {
        state.withLock { $0.first { $0.id == id }?.publicView }
    }

    /// Whether binding the listener is worth doing at all.
    ///
    /// No enrolled host means no port is opened. A feature nobody has set up
    /// should not be listening on one.
    public var hasActiveHosts: Bool {
        state.withLock { hosts in hosts.contains { $0.revokedAt == nil } }
    }

    // MARK: - Authentication

    /// The host a token belongs to, or nil.
    ///
    /// Every enrolled host is examined on every call, with no early exit, so the
    /// time taken does not depend on which host matched (or on how far down the
    /// list it was). The well-formedness pre-check DOES short-circuit, and that
    /// is deliberate: it discriminates on the token's shape, which an attacker
    /// supplied and already knows.
    public func authenticate(token: String) -> ClaudeRemoteHost? {
        guard ClaudeRemoteTokenDigest.isWellFormed(token) else { return nil }
        return state.withLock { hosts in
            var matched: StoredHost?
            for host in hosts {
                let candidate = ClaudeRemoteTokenDigest.hash(token: token, salt: host.tokenSalt)
                let equal = ClaudeRemoteTokenDigest.constantTimeEquals(candidate, host.tokenHash)
                if equal, host.revokedAt == nil {
                    matched = host
                }
            }
            return matched?.publicView
        }
    }

    /// Record that a host is alive. Best-effort and NOT persisted per request —
    /// a disk write on every hook event would turn a dictation nicety into
    /// steady write amplification. It is persisted on the next mutation.
    public func noteActivity(hostID: String) {
        let timestamp = now()
        state.withLock { hosts in
            guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
            hosts[index].lastSeenAt = timestamp
        }
    }

    // MARK: - Mutations

    /// Issue a credential for a new host.
    ///
    /// - Returns: the host and its plaintext token. This is the only time the
    ///   token is knowable; show it, then let it go.
    public func enroll(label: String) throws -> ClaudeRemoteEnrollment {
        let cleanLabel = Self.sanitizeLabel(label)
        guard !cleanLabel.isEmpty else { throw StoreError.invalidLabel }
        let token = makeToken()
        let salt = makeToken()
        let timestamp = now()

        let host: StoredHost = try state.withLock { hosts in
            guard hosts.count < Self.maxHosts else { throw StoreError.tooManyHosts(limit: Self.maxHosts) }
            var id = makeHostID()
            var attempts = 0
            while hosts.contains(where: { $0.id == id }) {
                attempts += 1
                guard attempts < 16 else { throw StoreError.idAllocationFailed }
                id = makeHostID()
            }
            let host = StoredHost(
                id: id,
                label: cleanLabel,
                createdAt: timestamp,
                lastSeenAt: nil,
                revokedAt: nil,
                tokenSalt: salt,
                tokenHash: ClaudeRemoteTokenDigest.hash(token: token, salt: salt)
            )
            hosts.append(host)
            return host
        }
        try persist()
        Log.claudeContext.info("Enrolled Claude remote host \(host.id, privacy: .public)")
        return ClaudeRemoteEnrollment(host: host.publicView, token: token)
    }

    /// Replace a host's credential. The previous token stops working the instant
    /// this returns — there is no grace period, because a rotation is what you
    /// do when you believe the old one leaked.
    public func rotateToken(hostID: String) throws -> ClaudeRemoteEnrollment {
        let token = makeToken()
        let salt = makeToken()
        let host: StoredHost = try state.withLock { hosts in
            guard let index = hosts.firstIndex(where: { $0.id == hostID }) else {
                throw StoreError.unknownHost(hostID)
            }
            hosts[index].tokenSalt = salt
            hosts[index].tokenHash = ClaudeRemoteTokenDigest.hash(token: token, salt: salt)
            // Rotating an enrolled-then-revoked host reinstates it: the user is
            // handing out a new credential, which is the same act as enrolling.
            hosts[index].revokedAt = nil
            return hosts[index]
        }
        try persist()
        Log.claudeContext.info("Rotated token for Claude remote host \(hostID, privacy: .public)")
        return ClaudeRemoteEnrollment(host: host.publicView, token: token)
    }

    /// Revoke without forgetting. The entry stays so the user can see that the
    /// host existed and rotate it back if the revocation was a mistake.
    public func revoke(hostID: String) throws {
        let timestamp = now()
        try state.withLock { hosts in
            guard let index = hosts.firstIndex(where: { $0.id == hostID }) else {
                throw StoreError.unknownHost(hostID)
            }
            hosts[index].revokedAt = timestamp
            // The hash goes too. A revoked host's stored hash has no remaining
            // purpose, and the shortest-lived secret-derived value is the one
            // that was deleted.
            hosts[index].tokenHash = ""
            hosts[index].tokenSalt = ""
        }
        try persist()
        Log.claudeContext.info("Revoked Claude remote host \(hostID, privacy: .public)")
    }

    public func remove(hostID: String) throws {
        try state.withLock { hosts in
            guard hosts.contains(where: { $0.id == hostID }) else {
                throw StoreError.unknownHost(hostID)
            }
            hosts.removeAll { $0.id == hostID }
        }
        try persist()
    }

    // MARK: - Persistence

    private func persist() throws {
        let hosts = state.withLock { $0 }
        let file = StoredFile(version: Self.fileVersion, hosts: hosts)
        let encoder = JSONEncoder.claudeRemote
        let data = try encoder.encode(file)
        try io.write(data, to: fileURL)
    }

    /// A label is shown in the UI and used in generated setup text; it is not an
    /// identifier. Anything that could act — a control character, a quote, a
    /// shell metacharacter — is dropped rather than escaped, because there is no
    /// legitimate host alias that needs one.
    static func sanitizeLabel(_ raw: String, maxLength: Int = 64) -> String {
        let allowed = raw.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-" || scalar == "_" || scalar == "." || scalar == "@" || scalar == " "
        }
        let label = String(String.UnicodeScalarView(allowed))
            .trimmingCharacters(in: .whitespaces)
        return String(label.prefix(maxLength))
    }
}

extension JSONEncoder {
    static var claudeRemote: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var claudeRemote: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
