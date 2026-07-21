import Foundation
import Network

/// Identifies endpoints for which an outbound TCP connection can settle the
/// macOS 15 Local Network permission before a dictation or polish request is in
/// flight. Public Internet and loopback destinations are deliberately excluded.
enum LocalNetworkEndpointPolicy {
    struct Target: Hashable, Sendable {
        let host: String
        let port: UInt16
    }

    static func preflightTarget(for endpoint: URL) -> Target? {
        guard let scheme = endpoint.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme),
              var host = endpoint.host?.lowercased(),
              !host.isEmpty
        else { return nil }

        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if let scopeMarker = host.firstIndex(of: "%") {
            host = String(host[..<scopeMarker])
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))

        guard isLocalNetworkHost(host) else { return nil }

        let resolvedPort = endpoint.port ?? defaultPort(for: scheme)
        guard let resolvedPort,
              (1...Int(UInt16.max)).contains(resolvedPort)
        else { return nil }

        return Target(host: host, port: UInt16(resolvedPort))
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }

    private static func isLocalNetworkHost(_ host: String) -> Bool {
        if let ipv4 = IPv4Address(host) {
            return isPrivateOrLinkLocalIPv4(Array(ipv4.rawValue))
        }

        if let ipv6 = IPv6Address(host) {
            return isPrivateOrLinkLocalIPv6(Array(ipv6.rawValue))
        }

        guard host != "localhost" else { return false }
        return !host.contains(".")
            || host.hasSuffix(".local")
            || host.hasSuffix(".lan")
            || host.hasSuffix(".home.arpa")
    }

    private static func isPrivateOrLinkLocalIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _):
            return true
        case (100, 64...127):
            return true
        case (169, 254):
            return true
        case (172, 16...31):
            return true
        case (192, 168):
            return true
        default:
            return false
        }
    }

    private static func isPrivateOrLinkLocalIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }

        // Unique-local (fc00::/7) and link-local (fe80::/10). ::1 remains
        // excluded, as do globally routable IPv6 addresses.
        if bytes[0] & 0xFE == 0xFC { return true }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }

        // IPv4-mapped IPv6 literals use the same private/link-local policy.
        let isIPv4Mapped = bytes[0..<10].allSatisfy { $0 == 0 }
            && bytes[10] == 0xFF && bytes[11] == 0xFF
        if isIPv4Mapped {
            return isPrivateOrLinkLocalIPv4(Array(bytes[12..<16]))
        }
        return false
    }
}

@MainActor
protocol LocalNetworkPermissionPreflighting: AnyObject {
    func preflight(endpoint: URL, reason: String)
}

/// Starts a payload-free TCP connection and retains it while macOS presents a
/// Local Network consent sheet. Ready and terminal failures are both sufficient:
/// the permission decision has happened before the real feature needs the host.
@MainActor
final class LocalNetworkPermissionPreflight: LocalNetworkPermissionPreflighting {
    private enum Completion: Sendable {
        case ready
        case failed(String)
        case cancelled
    }

    private static let queue = DispatchQueue(
        label: "com.localvoxtral.local-network-permission-preflight",
        qos: .utility
    )

    private var attemptedTargets: Set<LocalNetworkEndpointPolicy.Target> = []
    private var activeConnections: [LocalNetworkEndpointPolicy.Target: NWConnection] = [:]
    private var loggedWaitingTargets: Set<LocalNetworkEndpointPolicy.Target> = []

    #if DEBUG
    /// Test seam: when set, called instead of opening a real NWConnection, so
    /// tier-0 tests can drive the production dedupe/policy path networkless.
    var debugProbeStarter: ((LocalNetworkEndpointPolicy.Target) -> Void)?
    #endif

    func preflight(endpoint: URL, reason: String) {
        guard let target = LocalNetworkEndpointPolicy.preflightTarget(for: endpoint) else {
            return
        }
        guard attemptedTargets.insert(target).inserted else {
            Log.backends.info(
                "local-network permission preflight already requested for \(target.host, privacy: .private):\(target.port, privacy: .public)"
            )
            return
        }

        guard let port = NWEndpoint.Port(rawValue: target.port) else {
            Log.backends.error(
                "local-network permission preflight rejected invalid port \(target.port, privacy: .public)"
            )
            return
        }

        Log.backends.info(
            "local-network permission preflight requested reason=\(reason, privacy: .public) host=\(target.host, privacy: .private) port=\(target.port, privacy: .public)"
        )
        #if DEBUG
        if let debugProbeStarter {
            debugProbeStarter(target)
            return
        }
        #endif
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        activeConnections[target] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor [weak self] in self?.finish(target, completion: .ready) }
            case .failed(let error):
                let detail = String(describing: error)
                Task {
                    @MainActor [weak self] in
                    self?.finish(target, completion: .failed(detail))
                }
            case .cancelled:
                Task { @MainActor [weak self] in self?.finish(target, completion: .cancelled) }
            case .waiting(let error):
                let detail = String(describing: error)
                Task { @MainActor [weak self] in self?.logWaiting(target, detail: detail) }
            default:
                break
            }
        }
        connection.start(queue: Self.queue)
    }

    private func logWaiting(_ target: LocalNetworkEndpointPolicy.Target, detail: String) {
        guard loggedWaitingTargets.insert(target).inserted else { return }
        Log.backends.info(
            "local-network permission preflight waiting host=\(target.host, privacy: .private) port=\(target.port, privacy: .public) detail=\(detail, privacy: .public)"
        )
    }

    private func finish(
        _ target: LocalNetworkEndpointPolicy.Target,
        completion: Completion
    ) {
        guard let connection = activeConnections.removeValue(forKey: target) else { return }
        loggedWaitingTargets.remove(target)
        connection.stateUpdateHandler = nil
        connection.cancel()

        switch completion {
        case .ready:
            Log.backends.info(
                "local-network permission preflight connected host=\(target.host, privacy: .private) port=\(target.port, privacy: .public)"
            )
        case .failed(let detail):
            Log.backends.error(
                "local-network permission preflight failed host=\(target.host, privacy: .private) port=\(target.port, privacy: .public) detail=\(detail, privacy: .public)"
            )
        case .cancelled:
            Log.backends.info(
                "local-network permission preflight cancelled host=\(target.host, privacy: .private) port=\(target.port, privacy: .public)"
            )
        }
    }

    @MainActor
    deinit {
        for connection in activeConnections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }
}
