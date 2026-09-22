import Foundation
@testable import localvoxtral

/// Records every local-network preflight request instead of probing.
@MainActor
final class RecordingLocalNetworkPermissionPreflight: LocalNetworkPermissionPreflighting {
    struct Request {
        let endpoint: URL
        let reason: String
    }

    private(set) var requests: [Request] = []

    func preflight(endpoint: URL, reason: String) {
        requests.append(Request(endpoint: endpoint, reason: reason))
    }
}
