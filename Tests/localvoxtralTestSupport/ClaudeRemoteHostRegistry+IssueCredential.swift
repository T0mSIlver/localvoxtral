import Foundation
import localvoxtralCore

extension ClaudeRemoteHostRegistry {
    /// Issue (or replace) this host's extra credential for `purpose` in one
    /// call, returning the plaintext token. Refused for a revoked host.
    ///
    /// Tests only: it retires the previous credential in the same call, the
    /// one ordering the setup flow must not use, since the host does not hold
    /// the new token yet. Production goes through `prepareCredential`,
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
}
