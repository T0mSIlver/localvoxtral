import ClaudeContextWire
import Foundation
import Synchronization

#if canImport(Darwin)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#endif

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
    /// The alias the user enrolled with, when it is still a valid one.
    ///
    /// Nil for hosts enrolled before this was persisted. The label is NOT a
    /// usable substitute: the two are separate fields on the enrollment form,
    /// so a host named `prod` can have alias `builder`, and running setup
    /// against the name would act on a machine the user never chose (review
    /// finding, PR #197). Anything that would ssh somewhere therefore needs
    /// this, and treats nil as "ask, or copy only".
    public var sshHostAlias: String?
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var revokedAt: Date?
    /// Whether the app should hold this host's SSH `RemoteForward` open itself
    /// (`ClaudeRemoteForwardSupervisor`), instead of relying on one of the
    /// user's interactive sessions to hold it. Off by default: spawning ssh on
    /// someone's behalf is an opt-in, per host.
    ///
    /// It lives HERE rather than in a parallel preference so that removing a
    /// host removes the flag with it. A separate store would keep a dead host's
    /// switch alive and, worse, could hand it to a future host that reused the
    /// id.
    public var persistentForwardEnabled: Bool = false
    /// What authenticated hooks have reported about this host's
    /// `localvoxtral-remote` plugin version during this app session — the
    /// HIGHEST report seen, never lowered (see `notePluginVersion(hostID:_:)`).
    /// Nil until the first authenticated hook arrives — which is a different
    /// fact from `.headerAbsent`, an authenticated hook whose plugin predates
    /// the version header. Not a secret and never trusted: it only selects a
    /// fixed Settings string. Not persisted; see
    /// `notePluginVersion(hostID:_:)`.
    public var reportedPluginVersion: ClaudeRemotePluginVersionReport?
    /// Which extra credentials this host holds (see `ClaudeRemoteCredentialPurpose`).
    /// Purposes only, never anything derived from a token.
    public var extraCredentialPurposes: Set<ClaudeRemoteCredentialPurpose> = []
    /// The Vibe hooks version this host's authenticated Vibe hooks reported
    /// this app session, highest seen, under the same rules and for the same
    /// reason as `reportedPluginVersion`. Nil until a Vibe hook arrives.
    public var reportedVibeHooksVersion: String?

    public var isRevoked: Bool { revokedAt != nil }

    package init(
        id: String,
        label: String,
        sshHostAlias: String? = nil,
        createdAt: Date,
        lastSeenAt: Date? = nil,
        revokedAt: Date? = nil,
        persistentForwardEnabled: Bool = false,
        reportedPluginVersion: ClaudeRemotePluginVersionReport? = nil,
        extraCredentialPurposes: Set<ClaudeRemoteCredentialPurpose> = [],
        reportedVibeHooksVersion: String? = nil
    ) {
        self.id = id
        self.label = label
        self.sshHostAlias = sshHostAlias
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
        self.persistentForwardEnabled = persistentForwardEnabled
        self.reportedPluginVersion = reportedPluginVersion
        self.extraCredentialPurposes = extraCredentialPurposes
        self.reportedVibeHooksVersion = reportedVibeHooksVersion
    }
}

/// What an EXTRA credential of a host is for.
///
/// A host is enrolled with one token, and the app keeps only its hash: the
/// plaintext went into the Claude Code plugin's config once and is gone. A
/// second integration on the same host (the Vibe hooks) therefore cannot be
/// handed "the host's token", and rotating it would cut off the Claude Code
/// sessions using it. So a host may hold one more credential per purpose
/// (owner decision 2026-09-20).
///
/// An extra credential authenticates AS THE HOST: same id, same session
/// namespace, same origin channel. The purpose is a label for the UI and for
/// replacing the right one, not a permission: both tokens sit under one user
/// on one machine, so there is no boundary between them to enforce. Rotating
/// or revoking the host clears every extra credential, because both are what
/// you do when a token may have leaked.
public enum ClaudeRemoteCredentialPurpose: String, Sendable, Codable, CaseIterable {
    case vibe
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
    package static let allowedCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
    package static let minTokenLength = 16
    package static let maxTokenLength = 128

    public static func isWellFormed(_ token: String) -> Bool {
        guard token.count >= minTokenLength, token.count <= maxTokenLength else { return false }
        return token.allSatisfy { allowedCharacters.contains($0) }
    }

    /// HMAC-SHA256 keyed by the per-host salt, hex.
    ///
    /// The salt is per host and not itself a secret; it is here so that two
    /// hosts issued (improbably) the same token do not share a stored hash, and
    /// so the file cannot be attacked with one precomputed table across users.
    public static func hash(token: String, salt: String) -> String {
        HMACSHA256.authenticationCode(
            for: Data(token.utf8),
            key: Data(salt.utf8)
        ).map { String(format: "%02x", $0) }.joined()
    }

    /// Verify-only compatibility for registries written before hashes were
    /// framed. Never use this for a newly issued or rotated credential.
    package static func legacyHash(token: String, salt: String) -> String {
        var hasher = SHA256Hasher()
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
///
/// The threat this file defends against is a local process running as some OTHER
/// user (or a compromised world-writable parent) reaching the token hashes, or
/// steering our write somewhere it does not belong. Concretely:
///
/// * The containing directory is validated with the same rules as the broker's
///   socket directory — ours, not a symlink, not group/world-accessible — via
///   `ClaudeSocketGuard`. Nothing is written until that passes.
/// * The temp file is created `O_CREAT|O_EXCL|O_NOFOLLOW` at 0600, with a unique
///   name. `O_EXCL` means we never write through a file someone pre-created;
///   `O_NOFOLLOW` means we never write through a symlink they planted.
/// * The target is replaced with a POSIX `rename(2)` — no `remove` first. A
///   delete-then-move leaves a window where the file is simply absent, and a
///   crash inside it loses every enrollment.
/// * The temp file is removed on every failure path, so a full disk or a failed
///   rename does not litter the directory with 0600 droppings.
public struct ClaudeRemoteHostFileStoreIO: ClaudeRemoteHostStoreIO {
    public init() {}

    public func read(from url: URL) throws -> Data? {
        #if canImport(Darwin)
        // lstat, not `fileExists`: the question is what is AT this path, not what
        // it points to. A symlink here is not a store we are willing to read.
        guard let metadata = ClaudeSocketGuard.metadata(ofPath: url.path) else {
            // ONLY "there is nothing here" means "start fresh". `metadata` fails
            // for other reasons too — a parent we cannot traverse, a dead mount —
            // and returning nil for those would report an empty registry, which
            // reads downstream as "no hosts are enrolled" and silently revokes
            // every one of them. `metadata` lstats and returns immediately, so
            // errno is still its own here.
            guard errno == ENOENT else {
                throw ClaudeRemoteHostRegistry.StoreError.unreadable(path: url.path)
            }
            return nil
        }
        if let failure = ClaudeRemoteHostFileStoreIO.validateStoreFile(
            metadata,
            path: url.path,
            expectedUID: UInt32(geteuid())
        ) {
            throw failure
        }
        #else
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        #endif
        return try Data(contentsOf: url)
    }

    /// The read-side counterpart of `ClaudeSocketGuard.validateDirectory`, split
    /// out pure so every branch is testable without staging a hostile file.
    ///
    /// A store that is not ours, is a symlink, or is readable by anyone else is
    /// REPORTED, never used. Reading it anyway would mean authenticating remote
    /// hosts against hashes someone else could have written.
    package static func validateStoreFile(
        _ metadata: ClaudeSocketGuard.PathMetadata,
        path: String,
        expectedUID: UInt32
    ) -> ClaudeSocketGuard.PreconditionFailure? {
        if metadata.isSymlink { return .isSymlink(path) }
        if metadata.isDirectory { return .notADirectory(path) }
        if metadata.ownerUID != expectedUID {
            return .wrongOwner(path: path, owner: metadata.ownerUID, expected: expectedUID)
        }
        if metadata.mode & 0o077 != 0 {
            return .permissive(path: path, mode: metadata.mode)
        }
        return nil
    }

    public func write(_ data: Data, to url: URL) throws {
        #if canImport(Darwin)
        let directory = url.deletingLastPathComponent()
        // Reuses the broker's hardened path prep: creates 0700 if absent, and
        // otherwise REFUSES a directory that is a symlink, not ours, or loose.
        // It never "repairs" one — a directory in that state is a situation to
        // report, not to paper over.
        try ClaudeSocketGuard.prepareDirectory(at: directory.path)

        // Unique per attempt. A fixed name is shared mutable state between two
        // concurrent writers (and between us and anything else in the
        // directory): one would rename the other's half-written bytes over the
        // target.
        let temporaryPath = directory
            .appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt64.random(in: 0..<UInt64.max)).tmp")
            .path

        let fd = temporaryPath.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else {
            throw ClaudeRemoteHostRegistry.StoreError.writeFailed(path: url.path)
        }

        // From here on every exit removes the temp file. The only path that
        // must NOT is the successful rename, which consumes it.
        var renamed = false
        defer {
            close(fd)
            if !renamed { _ = temporaryPath.withCString { unlink($0) } }
        }

        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = ClaudeRemoteHostFileStoreIO.retryingOnEINTR {
                    LibC.write(fd, base.advanced(by: offset), raw.count - offset)
                }
                guard written > 0 else {
                    throw ClaudeRemoteHostRegistry.StoreError.writeFailed(path: url.path)
                }
                offset += written
            }
        }
        // The rename is atomic, but it does not imply the DATA reached the
        // platter. Without this a crash can leave the renamed target pointing at
        // unwritten blocks — an empty file where the enrollments were.
        guard fsync(fd) == 0 else {
            throw ClaudeRemoteHostRegistry.StoreError.writeFailed(path: url.path)
        }

        // POSIX rename(2): atomically replaces the target if it exists. No
        // `removeItem` first — that window is exactly when a crash loses the
        // file, and any reader in it sees "no hosts enrolled" rather than the
        // previous contents.
        let moved = temporaryPath.withCString { source in
            url.path.withCString { destination in
                rename(source, destination)
            }
        }
        guard moved == 0 else {
            throw ClaudeRemoteHostRegistry.StoreError.writeFailed(path: url.path)
        }
        renamed = true
        #else
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #endif
    }

    #if canImport(Darwin)
    @inline(__always)
    package static func retryingOnEINTR(_ body: () -> Int) -> Int {
        while true {
            let result = body()
            if result == -1 && errno == EINTR { continue }
            return result
        }
    }
    #endif
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
/// * **Every mutation is transactional with the file** — see `transact`. A
///   write that fails leaves memory exactly as it was, so the registry never
///   authenticates against a state the next launch will not read back.
///
/// `Mutex` + `Sendable`, per repo convention: the listener's connection threads
/// authenticate while the main actor may be enrolling.
public final class ClaudeRemoteHostRegistry: Sendable {
    /// Persisted shape. Internal: `tokenHash`/`tokenSalt` are storage details,
    /// and a public type carrying them invites someone to log one.
    /// One extra credential. Same digest construction as the host's own.
    package struct StoredCredential: Codable, Equatable {
        package var purpose: ClaudeRemoteCredentialPurpose
        package var tokenSalt: String
        package var tokenHash: String
        package var createdAt: Date
    }

    package struct StoredHost: Codable, Equatable {
        package var id: String
        package var label: String
        package var createdAt: Date
        package var lastSeenAt: Date?
        package var revokedAt: Date?
        package var tokenSalt: String
        package var tokenHash: String
        /// Absent means the legacy unframed SHA-256 construction. New and
        /// rotated credentials are HMAC v2; legacy hosts migrate on rotation.
        package var hashVersion: Int? = nil
        /// Absent for hosts enrolled before the alias was persisted. Optional
        /// rather than a new file version: an older build reading this file
        /// ignores the key, and a newer build reading an older file gets nil
        /// and degrades to copy-only — neither loses a host.
        package var sshHostAlias: String? = nil
        /// Absent means off, which is both the default and the safe reading:
        /// the app never starts spawning ssh for a host because a file it read
        /// was silent on the subject. Optional for the same
        /// forward/backward-compatibility reason as the alias above.
        package var persistentForwardEnabled: Bool? = nil
        /// Absent means none. Optional for the compatibility reason above: an
        /// older build ignores the key (and drops it on its next write, which
        /// costs a Vibe re-setup, never a host).
        package var extraCredentials: [StoredCredential]? = nil
        /// TRANSIENT, like `pluginVersionReport` below.
        package var vibeHooksVersionReport: String? = nil
        /// TRANSIENT: the highest plugin version this host's authenticated
        /// hooks have reported during this app session. Deliberately outside
        /// `CodingKeys` — it is refreshed by every hook and self-heals within
        /// one event, so persisting it would add a file field (and a
        /// stale-after-relaunch decision) for nothing. A relaunch reads
        /// "never heard" until the next hook, the same trade `lastSeenAt`
        /// already makes.
        package var pluginVersionReport: ClaudeRemotePluginVersionReport? = nil

        /// Exactly the persisted shape. `pluginVersionReport` stays out: an
        /// older build reading this file must not see an unknown key, and this
        /// build must never write state it cannot vouch for across a relaunch.
        package enum CodingKeys: String, CodingKey {
            case id
            case label
            case createdAt
            case lastSeenAt
            case revokedAt
            case tokenSalt
            case tokenHash
            case hashVersion
            case sshHostAlias
            case persistentForwardEnabled
            case extraCredentials
        }

        package var publicView: ClaudeRemoteHost {
            ClaudeRemoteHost(
                id: id,
                label: label,
                sshHostAlias: sshHostAlias,
                createdAt: createdAt,
                lastSeenAt: lastSeenAt,
                revokedAt: revokedAt,
                persistentForwardEnabled: persistentForwardEnabled ?? false,
                reportedPluginVersion: pluginVersionReport,
                extraCredentialPurposes: Set((extraCredentials ?? []).map(\.purpose)),
                reportedVibeHooksVersion: vibeHooksVersionReport
            )
        }

        package init(
            id: String,
            label: String,
            createdAt: Date,
            lastSeenAt: Date? = nil,
            revokedAt: Date? = nil,
            tokenSalt: String,
            tokenHash: String,
            hashVersion: Int? = nil,
            sshHostAlias: String? = nil,
            persistentForwardEnabled: Bool? = nil,
            extraCredentials: [StoredCredential]? = nil,
            vibeHooksVersionReport: String? = nil,
            pluginVersionReport: ClaudeRemotePluginVersionReport? = nil
        ) {
            self.id = id
            self.label = label
            self.createdAt = createdAt
            self.lastSeenAt = lastSeenAt
            self.revokedAt = revokedAt
            self.tokenSalt = tokenSalt
            self.tokenHash = tokenHash
            self.hashVersion = hashVersion
            self.sshHostAlias = sshHostAlias
            self.persistentForwardEnabled = persistentForwardEnabled
            self.extraCredentials = extraCredentials
            self.vibeHooksVersionReport = vibeHooksVersionReport
            self.pluginVersionReport = pluginVersionReport
        }
    }

    package struct StoredFile: Codable, Equatable {
        package var version: Int
        package var hosts: [StoredHost]

        package enum CodingKeys: String, CodingKey {
            case version = "v"
            case hosts
        }

        package init(version: Int, hosts: [StoredHost]) {
            self.version = version
            self.hosts = hosts
        }
    }

    public enum StoreError: Error, Equatable {
        case unknownHost(String)
        case unreadable(path: String)
        case unsupportedVersion(Int)
        case writeFailed(path: String)
        case invalidLabel
        case tooManyHosts(limit: Int)
        /// An extra credential was requested for a revoked host.
        case hostRevoked(String)
        /// The host's token was rotated between preparing an extra credential
        /// and committing it.
        case hostCredentialChanged(String)
        /// The id allocator failed to produce an unused id. Effectively
        /// impossible; reported rather than looped on forever.
        case idAllocationFailed
    }

    /// Bump on any incompatible change to `StoredFile`.
    package static let fileVersion = 1
    package static let currentHashVersion = 2

    /// Cap on enrolled hosts. Not a security boundary — a bound on a file we
    /// read on every listener start.
    public static let maxHosts = 32

    private let state: Mutex<[StoredHost]>
    /// Serializes each mutate+write TRANSACTION. See `transact` for why `state`
    /// alone is not enough to keep memory and disk coherent.
    private let persistLock = Mutex<Int>(0)
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
            // The shared app-support directory already exists as 0755 on
            // normal installs. The hardened store requires a leaf it alone
            // owns at 0700; never try to tighten permissions on the shared
            // parent and surprise unrelated app data.
            .appendingPathComponent("claude", isDirectory: true)
            .appendingPathComponent("claude-remote-hosts.json")
    }

    // MARK: - Queries

    public func hosts() -> [ClaudeRemoteHost] {
        state.withLock { $0.map(\.publicView) }.sorted { $0.createdAt < $1.createdAt }
    }

    public func host(id: String) -> ClaudeRemoteHost? {
        state.withLock { $0.first { $0.id == id }?.publicView }
    }

    /// Active hosts whose enrolled ssh alias IS this destination.
    ///
    /// The join side of the alias: the process table says the focused terminal
    /// is an ssh client going to `builder`, and this answers "and is `builder`
    /// a host the user enrolled?". Revoked hosts are not candidates — a
    /// credential the user withdrew must not keep authorizing a context join.
    ///
    /// Compared case-insensitively, because a hostname is, and an ssh config
    /// alias is used as one in practice. That makes the comparison WIDER, which
    /// is safe only because a match is a precondition of the remote herdr arm
    /// and never the join: the pane id, herdr's own session claim, and the
    /// foreground process
    /// all still have to agree afterwards.
    ///
    /// Returns the STORED alias, not the destination the user typed: that is
    /// the string `ClaudeRemoteEnrollmentService.isValidHostAlias` vetted at
    /// enrollment, and it is the one allowed to reach an argv.
    public func hosts(matchingSSHDestination destination: String) -> [ClaudeRemoteHost] {
        let needle = destination.lowercased()
        guard !needle.isEmpty else { return [] }
        return hosts().filter { host in
            guard !host.isRevoked, let alias = host.sshHostAlias else { return false }
            return alias.lowercased() == needle
        }
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
            authenticatedHostLocked(token: token, hosts: hosts)?.publicView
        }
    }

    /// Re-authenticate and perform one synchronous action under the same host
    /// lock. Revocation cannot commit between the check and `body`, closing the
    /// listener's authenticate-then-ingest race. `body` must not call back into
    /// this host registry; the listener only writes to the separate session
    /// registry here.
    public func withAuthenticatedHost<Outcome>(
        token: String,
        expectedHostID: String,
        _ body: (ClaudeRemoteHost) -> Outcome
    ) -> Outcome? {
        guard ClaudeRemoteTokenDigest.isWellFormed(token) else { return nil }
        return state.withLock { hosts in
            guard let host = authenticatedHostLocked(token: token, hosts: hosts),
                  host.id == expectedHostID
            else { return nil }
            return body(host.publicView)
        }
    }

    private func authenticatedHostLocked(token: String, hosts: [StoredHost]) -> StoredHost? {
        var matched: StoredHost?
        for host in hosts {
            let candidate: String
            switch host.hashVersion ?? 1 {
            case 1:
                candidate = ClaudeRemoteTokenDigest.legacyHash(token: token, salt: host.tokenSalt)
            case Self.currentHashVersion:
                candidate = ClaudeRemoteTokenDigest.hash(token: token, salt: host.tokenSalt)
            default:
                // Still perform a fixed-length comparison for every host.
                candidate = String(repeating: "0", count: 64)
            }
            let equal = ClaudeRemoteTokenDigest.constantTimeEquals(candidate, host.tokenHash)
            if equal, host.revokedAt == nil {
                matched = host
            }
            // Extra credentials, under the same rule: every stored hash is
            // compared, a match never short-circuits, and a revoked host
            // matches nothing (revocation clears these too; the check stays in
            // case a file says otherwise).
            for credential in host.extraCredentials ?? [] {
                let extra = ClaudeRemoteTokenDigest.hash(token: token, salt: credential.tokenSalt)
                if ClaudeRemoteTokenDigest.constantTimeEquals(extra, credential.tokenHash),
                   !credential.tokenHash.isEmpty, host.revokedAt == nil {
                    matched = host
                }
            }
        }
        return matched
    }

    /// Record that a host is alive. Best-effort and NOT persisted per request —
    /// a disk write on every hook event would turn a dictation nicety into
    /// steady write amplification. It is persisted on the next mutation.
    public func noteActivity(hostID: String) {
        let timestamp = now()
        persistLock.withLock { _ in
            state.withLock { hosts in
                guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
                hosts[index].lastSeenAt = timestamp
            }
        }
    }

    /// Record what an authenticated hook reported about its plugin version.
    ///
    /// The listener calls this only for finally-ACCEPTED requests — the same
    /// points `noteActivity` is — never for one the revocation re-check
    /// refused, so an in-flight request cannot mutate a host whose
    /// credential was withdrawn mid-request (and rotation would preserve the
    /// field into the reinstated host).
    ///
    /// Same best-effort discipline and the same lock order as
    /// `noteActivity(hostID:)`: in-memory under `persistLock` → `state`, so a
    /// concurrent transaction's candidate installation cannot clobber the
    /// report, and the report cannot clobber `lastSeenAt` — the two note
    /// different facts about the same request and each must survive the other.
    /// Never written to disk per request (the field is transient by design);
    /// recording on an unknown host is a no-op, like `noteActivity`.
    ///
    /// MONOTONE by construction: the recorded value is the HIGHEST report
    /// this app session (`nil` < `.headerAbsent` < `.version` in numeric
    /// order) and only a strictly higher report replaces it. Claude Code
    /// applies a plugin update only on session restart, so after "Update
    /// Plugin…" succeeds a host's already-running sessions keep executing the
    /// OLD plugin's shim — their hooks arrive header-less, and a
    /// last-writer-wins record would let them flip a verified host back to
    /// "Plugin update available" (the 2026-09-17 follow-up defect). The
    /// accepted cost: a genuine plugin DOWNGRADE on the host stays unread
    /// until this app relaunches — a rare act that the update flow itself
    /// never performs.
    public func notePluginVersion(hostID: String, _ report: ClaudeRemotePluginVersionReport) {
        persistLock.withLock { _ in
            state.withLock { hosts in
                guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
                // Replace only when strictly higher; `nil` recorded means
                // "never heard", which any report outranks.
                guard hosts[index].pluginVersionReport.map({ report > $0 }) ?? true else { return }
                hosts[index].pluginVersionReport = report
            }
        }
    }

    /// The Vibe hooks version an authenticated Vibe hook reported. Highest
    /// wins and nothing is persisted, exactly as `notePluginVersion`: a host's
    /// running Vibe sessions keep the hooks they started with.
    public func noteVibeHooksVersion(hostID: String, _ version: String) {
        guard ClaudeRemotePluginVersionCodec.isAcceptableVersion(version) else { return }
        persistLock.withLock { _ in
            state.withLock { hosts in
                guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
                guard hosts[index].vibeHooksVersionReport.map({
                    ClaudeRemotePluginVersionCodec.isVersion($0, olderThan: version)
                }) ?? true else { return }
                hosts[index].vibeHooksVersionReport = version
            }
        }
    }

    // MARK: - Mutations

    /// Issue (or replace) this host's extra credential for `purpose`.
    ///
    /// - Returns: the plaintext token, knowable only here.
    /// Refused for a revoked host: reinstating one is `rotateToken`'s job, and
    /// it is a decision about the whole host.
    ///
    /// FOR TESTS. It retires the previous credential in the same call, which
    /// is the one ordering the setup flow must not use: the host does not hold
    /// the new token yet. Production code goes through `prepareCredential`,
    /// `commitCredential` and, once the host has the token,
    /// `retireOtherCredentials`.
    package func issueCredential(
        hostID: String, purpose: ClaudeRemoteCredentialPurpose
    ) throws -> String {
        let pending = try prepareCredential(hostID: hostID, purpose: purpose)
        try commitCredential(pending, hostID: hostID)
        try retireOtherCredentials(hostID: hostID, keeping: pending)
        return pending.token
    }

    /// A credential that exists only in memory until `commitCredential`.
    ///
    /// Two phases because the token has to reach the host BEFORE the store
    /// trusts it: committing first would replace a working credential with
    /// one the host never received whenever the ssh run fails.
    public struct PendingCredential: Sendable {
        public let token: String
        package let purpose: ClaudeRemoteCredentialPurpose
        package let salt: String
        /// The host's own credential as it was when this one was prepared. A
        /// rotation replaces it, and a credential prepared BEFORE a rotation
        /// must not be committed after it: the rotation answered a suspected
        /// leak, and this token was already on its way to the host by then.
        package let hostGeneration: String
    }

    public func prepareCredential(
        hostID: String, purpose: ClaudeRemoteCredentialPurpose
    ) throws -> PendingCredential {
        guard let host = state.withLock({ hosts in hosts.first { $0.id == hostID } }) else {
            throw StoreError.unknownHost(hostID)
        }
        guard host.revokedAt == nil else { throw StoreError.hostRevoked(hostID) }
        let generation = host.tokenSalt + ":" + host.tokenHash
        return PendingCredential(
            token: makeToken(), purpose: purpose, salt: makeToken(), hostGeneration: generation
        )
    }

    /// Trust `pending` IN ADDITION to the purpose's current credential.
    ///
    /// Both stay valid until `retireOtherCredentials`, because the caller is
    /// about to replace the token file on the host and cannot know whether
    /// that write landed if the connection dies: with only the old one
    /// trusted a landed write locks the host out, with only the new one a
    /// failed write does. At most one previous credential is kept.
    public func commitCredential(_ pending: PendingCredential, hostID: String) throws {
        let token = pending.token
        let salt = pending.salt
        let purpose = pending.purpose
        let timestamp = now()
        try transact { hosts in
            guard let index = hosts.firstIndex(where: { $0.id == hostID }) else {
                throw StoreError.unknownHost(hostID)
            }
            guard hosts[index].revokedAt == nil else { throw StoreError.hostRevoked(hostID) }
            guard hosts[index].tokenSalt + ":" + hosts[index].tokenHash == pending.hostGeneration else {
                throw StoreError.hostCredentialChanged(hostID)
            }
            var credentials = hosts[index].extraCredentials ?? []
            let previous = credentials.filter { $0.purpose == purpose }.max { $0.createdAt < $1.createdAt }
            credentials.removeAll { $0.purpose == purpose }
            if let previous { credentials.append(previous) }
            credentials.append(StoredCredential(
                purpose: purpose,
                tokenSalt: salt,
                tokenHash: ClaudeRemoteTokenDigest.hash(token: token, salt: salt),
                createdAt: timestamp
            ))
            hosts[index].extraCredentials = credentials
            hosts[index].vibeHooksVersionReport = nil
        }
        Log.claudeContext.info(
            "Issued \(purpose.rawValue, privacy: .public) credential for Claude remote host \(hostID, privacy: .public)"
        )
    }

    /// The host has `pending`'s token now: drop the purpose's other credential.
    public func retireOtherCredentials(hostID: String, keeping pending: PendingCredential) throws {
        let kept = ClaudeRemoteTokenDigest.hash(token: pending.token, salt: pending.salt)
        try transact { hosts in
            guard let index = hosts.firstIndex(where: { $0.id == hostID }) else {
                throw StoreError.unknownHost(hostID)
            }
            hosts[index].extraCredentials?.removeAll {
                $0.purpose == pending.purpose && $0.tokenHash != kept
            }
        }
    }

    /// Issue a credential for a new host.
    ///
    /// - Returns: the host and its plaintext token. This is the only time the
    ///   token is knowable; show it, then let it go.
    /// - Parameter sshHostAlias: the alias the user typed. Stored only when it
    ///   is a valid alias — a stored value is later allowed to reach `ssh`'s
    ///   argv, so it is checked here rather than trusted from a caller.
    public func enroll(label: String, sshHostAlias: String? = nil) throws -> ClaudeRemoteEnrollment {
        let cleanLabel = Self.sanitizeLabel(label)
        guard !cleanLabel.isEmpty else { throw StoreError.invalidLabel }
        let cleanAlias = sshHostAlias.flatMap {
            ClaudeRemoteEnrollmentService.isValidHostAlias($0) ? $0 : nil
        }
        let token = makeToken()
        let salt = makeToken()
        let timestamp = now()

        let host: StoredHost = try transact { hosts in
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
                tokenHash: ClaudeRemoteTokenDigest.hash(token: token, salt: salt),
                hashVersion: Self.currentHashVersion,
                sshHostAlias: cleanAlias
            )
            hosts.append(host)
            return host
        }
        Log.claudeContext.info("Enrolled Claude remote host \(host.id, privacy: .public)")
        return ClaudeRemoteEnrollment(host: host.publicView, token: token)
    }

    /// Replace a host's credential. The previous token stops working the instant
    /// this returns — there is no grace period, because a rotation is what you
    /// do when you believe the old one leaked.
    public func rotateToken(hostID: String) throws -> ClaudeRemoteEnrollment {
        let token = makeToken()
        let salt = makeToken()
        let host: StoredHost = try transact { hosts in
            guard let index = hosts.firstIndex(where: { $0.id == hostID }) else {
                throw StoreError.unknownHost(hostID)
            }
            hosts[index].tokenSalt = salt
            hosts[index].tokenHash = ClaudeRemoteTokenDigest.hash(token: token, salt: salt)
            hosts[index].hashVersion = Self.currentHashVersion
            // A rotation answers a suspected leak, and the extra credentials
            // sat next to the leaked one. They go; Vibe setup mints a new one.
            hosts[index].extraCredentials = nil
            hosts[index].vibeHooksVersionReport = nil
            // Rotating an enrolled-then-revoked host reinstates it: the user is
            // handing out a new credential, which is the same act as enrolling.
            hosts[index].revokedAt = nil
            return hosts[index]
        }
        Log.claudeContext.info("Rotated token for Claude remote host \(hostID, privacy: .public)")
        return ClaudeRemoteEnrollment(host: host.publicView, token: token)
    }

    /// Revoke without forgetting. The entry stays so the user can see that the
    /// host existed and rotate it back if the revocation was a mistake.
    public func revoke(hostID: String) throws {
        let timestamp = now()
        try transact { hosts in
            guard let index = hosts.firstIndex(where: { $0.id == hostID }) else {
                throw StoreError.unknownHost(hostID)
            }
            hosts[index].revokedAt = timestamp
            // The hash goes too. A revoked host's stored hash has no remaining
            // purpose, and the shortest-lived secret-derived value is the one
            // that was deleted.
            hosts[index].tokenHash = ""
            hosts[index].tokenSalt = ""
            hosts[index].extraCredentials = nil
        }
        Log.claudeContext.info("Revoked Claude remote host \(hostID, privacy: .public)")
    }

    /// Turn the app-held forward on or off for one host.
    ///
    /// Transactional like every other mutation: a flag memory accepted and disk
    /// refused would mean an ssh process this app starts on every launch and a
    /// Settings toggle that reads off.
    public func setPersistentForwardEnabled(_ enabled: Bool, hostID: String) throws {
        try transact { hosts in
            guard let index = hosts.firstIndex(where: { $0.id == hostID }) else {
                throw StoreError.unknownHost(hostID)
            }
            hosts[index].persistentForwardEnabled = enabled
        }
        Log.claudeContext.info(
            "Claude remote persistent forward \(enabled ? "enabled" : "disabled", privacy: .public) for host \(hostID, privacy: .public)"
        )
    }

    public func remove(hostID: String) throws {
        try transact { hosts in
            guard hosts.contains(where: { $0.id == hostID }) else {
                throw StoreError.unknownHost(hostID)
            }
            hosts.removeAll { $0.id == hostID }
        }
    }

    // MARK: - Persistence

    /// Mutate the registry and persist the result, as one transaction.
    ///
    /// A mutation that memory accepted and the disk refused is a lie with a
    /// delay on it: the UI shows the host enrolled, the listener authenticates
    /// it, and the next launch reads a file that never heard of it. So `body`
    /// mutates a private candidate copy. The candidate is installed into memory
    /// only after its write succeeds; a throw leaves the live state untouched.
    ///
    /// **Lock order is always persistLock → state, never the reverse**, so this
    /// cannot deadlock. Two properties come out of holding `persistLock` across
    /// the whole transaction rather than only the write:
    ///
    /// * **Disk cannot fall behind memory.** Mutations release `state` before
    ///   writing, so unserialized callers can interleave as: A snapshots {A}, B
    ///   snapshots {A,B}, B writes {A,B}, A writes {A} — the last writer puts a
    ///   STALE snapshot on disk, silently un-enrolling B.
    /// * **A failed write is never observable as live state.** Authentication
    ///   and queries keep seeing the previous state while I/O is in flight.
    ///   There is no optimistic enrollment or revocation to roll back later.
    ///
    /// `state`'s mutex is deliberately NOT held across the I/O. Authentication
    /// runs on listener connection threads and continues against the last
    /// committed state instead of blocking on disk. `noteActivity` does take
    /// `persistLock` (without doing I/O), so installing the candidate cannot
    /// overwrite a concurrent `lastSeenAt` update.
    private func transact<Outcome>(_ body: (inout [StoredHost]) throws -> Outcome) throws -> Outcome {
        try persistLock.withLock { _ -> Outcome in
            var proposed = state.withLock { $0 }
            let result = try body(&proposed)
            let file = StoredFile(version: Self.fileVersion, hosts: proposed)
            let data = try JSONEncoder.claudeRemote.encode(file)
            try io.write(data, to: fileURL)
            state.withLock { $0 = proposed }
            return result
        }
    }

    /// A label is shown in the UI and used in generated setup text; it is not an
    /// identifier. Anything that could act — a control character, a quote, a
    /// shell metacharacter — is dropped rather than escaped, because there is no
    /// legitimate host alias that needs one.
    package static func sanitizeLabel(_ raw: String, maxLength: Int = 64) -> String {
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
    package static var claudeRemote: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    package static var claudeRemote: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
