import Foundation
import Synchronization

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
            default:
                continue
            }
        }
        guard let hostname, let port else { return nil }
        return Identity(hostname: hostname, port: port, user: user)
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
