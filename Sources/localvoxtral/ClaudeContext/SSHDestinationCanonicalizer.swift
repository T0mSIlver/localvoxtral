import Foundation
import Synchronization

/// Whether a destination's effective ssh config routes it through a jump host,
/// as a SHAPE — never the host's name, so it is safe in the log and the
/// dogfood record.
///
/// **This is a diagnosis, not a capability.** A ProxyJump'd connection cannot
/// be joined by the plain-ssh arm, and the reason is a measured property of
/// unprivileged Unix rather than a gap in this code — see
/// `docs/agent/invariants.md`. What the shape buys is an abstention that names
/// the user's own config instead of guessing at a ControlMaster.
enum SSHProxyJumpShape: String, Sendable, Equatable {
    /// No `ProxyJump` line, or an explicit `none`.
    case none
    /// Exactly one hop.
    case singleHop
    /// A comma-separated chain.
    case chain

    init(configuredValue value: String) {
        // A leading `none` disables every hop before it, so `none,dell1` is
        // ONE hop and not a chain. Kept because the two shapes report
        // different causes and the wrong one sends a reader looking for a
        // chain that is not there.
        let hops = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .drop { $0.lowercased() == "none" }
            .filter { !$0.isEmpty }
        switch hops.count {
        case 0: self = .none
        case 1: self = .singleHop
        default: self = .chain
        }
    }
}

/// Resolves ssh destination operands through the user's effective ssh config.
///
/// This is deliberately a fallback signal: callers first try the enrolled
/// alias exactly, and use these identities only when that produces no match.
final class SSHDestinationCanonicalizer: Sendable {
    struct Identity: Sendable, Equatable {
        let hostname: String
        let port: UInt16
        /// Parsed for the log's benefit only — NEVER compared. `ssh -G`
        /// always prints an effective `user` line (defaulting to the local
        /// username), and the probe strips `user@` from the operand before it
        /// reaches this type, so the operand side always carries that local
        /// default. Comparing it against an alias whose config sets `User`
        /// (the common build-host shape) would reject the very match this
        /// fallback exists for, while conveying nothing about what the user
        /// typed. Two enrollments to one (hostname, port) under different
        /// remote users both match and land in the existing multiple-match
        /// abstention downstream — fail-closed, as before.
        let user: String?
        /// The effective `ProxyJump`, as a SHAPE and never as a host name.
        ///
        /// Never compared either — it exists so an abstention can say WHY. A
        /// ProxyJump'd connection is carried by an `ssh -W` child, so the
        /// surface's own ssh holds no TCP socket, and the plain-ssh arm's
        /// refusal for it used to read "a ControlMaster client or a
        /// ProxyCommand": true, unactionable, and wrong about the cause. The
        /// owner's Mac hit exactly that (field report, 2026-09-06).
        let proxyJump: SSHProxyJumpShape

        /// `proxyJump` defaults, so every existing construction site keeps
        /// meaning what it meant: a config with no `ProxyJump` line.
        init(
            hostname: String,
            port: UInt16,
            user: String?,
            proxyJump: SSHProxyJumpShape = .none
        ) {
            self.hostname = hostname
            self.port = port
            self.user = user
            self.proxyJump = proxyJump
        }

        func matches(_ other: Identity) -> Bool {
            hostname == other.hostname && port == other.port
        }
    }

    typealias ProcessRunner = @Sendable (
        _ executableURL: URL,
        _ invocation: ClaudeRemoteEnrollmentService.Invocation
    ) throws -> ClaudeRemoteEnrollmentService.RunResult

    static let executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    static let defaultTTL: TimeInterval = 5 * 60
    static let defaultTimeout: TimeInterval = 2
    private static let maxCacheEntries = 128

    private enum CachedOutcome: Sendable {
        case resolved(Identity)
        case failed
    }

    private struct CacheEntry: Sendable {
        let outcome: CachedOutcome
        let cachedAt: Date
    }

    private let cache = Mutex<[String: CacheEntry]>([:])
    private let ttl: TimeInterval
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date
    private let runner: ProcessRunner

    init(
        ttl: TimeInterval = defaultTTL,
        timeout: TimeInterval = defaultTimeout,
        now: @escaping @Sendable () -> Date = { Date() },
        runner: @escaping ProcessRunner
    ) {
        self.ttl = ttl
        self.timeout = timeout
        self.now = now
        self.runner = runner
    }

    /// Active enrolled hosts sharing the operand's effective `(hostname,
    /// port, user?)` identity. Any failed resolution rejects the entire
    /// fallback, so partial subprocess success can never select a host.
    func matchingHosts(
        destination: String,
        enrolledHosts: [ClaudeRemoteHost]
    ) async -> [ClaudeRemoteHost] {
        let candidates = enrolledHosts.filter { !$0.isRevoked && $0.sshHostAlias != nil }
        guard !candidates.isEmpty,
              let destinationIdentity = await identity(for: destination)
        else { return [] }

        var identities = Array<Identity?>(repeating: nil, count: candidates.count)
        await withTaskGroup(of: (Int, Identity?).self) { group in
            for (index, host) in candidates.enumerated() {
                guard let alias = host.sshHostAlias else { continue }
                group.addTask { [self] in (index, await identity(for: alias)) }
            }
            for await (index, identity) in group {
                identities[index] = identity
            }
        }

        // A failure for even one candidate makes the canonical view incomplete.
        // Fall open to the exact-match behavior instead of selecting from a
        // partial host set.
        guard identities.allSatisfy({ $0 != nil }) else {
            Log.claudeContext.info(
                "SSH destination canonicalization failed for an enrolled host; exact matching retained"
            )
            return []
        }

        let matches: [ClaudeRemoteHost] = candidates.enumerated().compactMap { index, host in
            guard let identity = identities[index], destinationIdentity.matches(identity) else {
                return nil
            }
            return host
        }
        if matches.count == 1 {
            Log.claudeContext.info("SSH destination matched an enrolled host via canonical config")
        } else if matches.count > 1 {
            Log.claudeContext.info(
                "SSH destination matched multiple enrolled hosts via canonical config"
            )
        }
        return matches
    }

    /// The effective `ProxyJump` shape for one operand, through the same
    /// cached `ssh -G` the identity fallback uses — so an abstention costs no
    /// extra process spawn, and a config that cannot be read says `nil` rather
    /// than guessing `none`.
    ///
    /// `ssh -G` evaluates the user's `Match exec` blocks, so this can run a
    /// command the user configured, once per operand per TTL, bounded by the
    /// same 2 s timeout as the identity lookup. That is the cost of asking ssh
    /// what ssh would do; the alternative is reimplementing its config
    /// resolution, which this file exists not to do.
    func proxyJumpShape(for operand: String) async -> SSHProxyJumpShape? {
        await identity(for: operand)?.proxyJump
    }

    private func identity(for operand: String) async -> Identity? {
        // Apply the probe's existing operand policy BEFORE any subprocess sees
        // the string. In particular, refused URI/punctuation shapes never
        // become arguments to a command.
        guard SSHDestinationTTYProbe.normalizedDestination(operand) != nil else {
            Log.claudeContext.info(
                "SSH destination canonicalization failed: operand refused before process spawn"
            )
            return nil
        }

        let timestamp = now()
        if let cached = cache.withLock({ storage -> CachedOutcome? in
            guard let entry = storage[operand] else { return nil }
            guard timestamp.timeIntervalSince(entry.cachedAt) <= ttl else {
                storage.removeValue(forKey: operand)
                return nil
            }
            return entry.outcome
        }) {
            Log.claudeContext.info("SSH destination canonicalization cache hit")
            switch cached {
            case .resolved(let identity): return identity
            case .failed: return nil
            }
        }

        let invocation = ClaudeRemoteEnrollmentService.Invocation(
            argv: ["ssh", "-G", "--", operand],
            standardInput: Data(),
            timeout: timeout
        )
        let outcome: CachedOutcome
        do {
            // `ssh -G` only prints effective configuration; it performs no
            // network I/O. The live runner closes stdin and bounds the process.
            let result = try await Task.detached(priority: .utility) { [runner] in
                try runner(Self.executableURL, invocation)
            }.value
            guard result.succeeded, let parsed = Self.parse(result.message) else {
                Log.claudeContext.info(
                    "SSH destination canonicalization failed: ssh config output unavailable"
                )
                outcome = .failed
                store(outcome, for: operand, at: timestamp)
                return nil
            }
            outcome = .resolved(parsed)
        } catch {
            Log.claudeContext.info(
                "SSH destination canonicalization failed: ssh config process did not complete"
            )
            outcome = .failed
        }
        store(outcome, for: operand, at: timestamp)
        if case .resolved(let identity) = outcome { return identity }
        return nil
    }

    private func store(_ outcome: CachedOutcome, for operand: String, at timestamp: Date) {
        cache.withLock { storage in
            storage = storage.filter { timestamp.timeIntervalSince($0.value.cachedAt) <= ttl }
            if storage.count >= Self.maxCacheEntries,
               let oldest = storage.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key {
                storage.removeValue(forKey: oldest)
            }
            storage[operand] = CacheEntry(outcome: outcome, cachedAt: timestamp)
        }
    }

    static func parse(_ output: String) -> Identity? {
        var hostname: String?
        var port: UInt16?
        var user: String?
        var proxyJump: SSHProxyJumpShape = .none

        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let key = fields[0].lowercased()
            let value = String(fields[1])
            switch key {
            case "hostname":
                guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
                let normalized = value.lowercased()
                guard hostname == nil || hostname == normalized else { return nil }
                hostname = normalized
            case "port":
                guard let parsed = UInt16(value), parsed > 0 else { return nil }
                guard port == nil || port == parsed else { return nil }
                port = parsed
            case "user":
                guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
                guard user == nil || user == value else { return nil }
                user = value
            case "proxyjump":
                // `ssh -G` omits the line entirely when unset AND when it is
                // explicitly `none` (measured on OpenSSH 9.x and 10.0p2,
                // 2026-09-06: both print no `proxyjump` line at all), so the
                // missing-line default below is what answers for both. A chain
                // is comma-separated, and a list that merely BEGINS with
                // `none` is printed raw. The VALUE is deliberately dropped
                // here — only the shape survives, because this reaches the
                // log.
                proxyJump = SSHProxyJumpShape(configuredValue: value)
            default:
                continue
            }
        }
        guard let hostname, let port else { return nil }
        return Identity(hostname: hostname, port: port, user: user, proxyJump: proxyJump)
    }
}

#if canImport(Darwin)
extension SSHDestinationCanonicalizer {
    static func live() -> SSHDestinationCanonicalizer {
        let liveRunner = ClaudeRemoteEnrollmentService.processRunner(sshExecutableURL: executableURL)
        return SSHDestinationCanonicalizer { executableURL, invocation in
            guard executableURL == Self.executableURL else {
                throw LiveRunnerError.unexpectedExecutable
            }
            return try liveRunner(invocation)
        }
    }

    private enum LiveRunnerError: Error {
        case unexpectedExecutable
    }
}
#endif
