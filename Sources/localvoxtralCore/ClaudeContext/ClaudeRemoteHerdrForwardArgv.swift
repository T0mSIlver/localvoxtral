import Foundation

/// The `ssh -L` argv of the herdr forward. It lives in the core so the
/// remote forward supervisor, which runs the same forward when it keeps one
/// up, builds on Linux; `ClaudeRemoteHerdrForwardService.argv` forwards here.
package enum ClaudeRemoteHerdrForwardArgv {
    /// The exact argv. Assembled in one static function so a test can assert
    /// every token of it — this is a command line built partly from a remote
    /// machine's strings, and "what exactly do we run" must be answerable
    /// without reading the spawn path.
    ///
    /// Two options the design review asked for are deliberately ABSENT, both
    /// falsified against OpenSSH 10.0 before this shipped:
    ///
    /// * `ClearAllForwardings=yes` clears forwardings "specified in the
    ///   configuration files OR ON THE COMMAND LINE", and the clearing runs
    ///   after all option parsing — so it deletes the very `-L` this exists
    ///   for. Measured: with it, the local socket is never created; without
    ///   it, it appears.
    /// * `ExitOnForwardFailure=yes` would make the ENROLLED host's own
    ///   `RemoteForward 8473` — which the user's live interactive session is
    ///   normally already holding — a fatal error for this connection.
    ///   Measured: with it, ssh exits ("Error: remote port forwarding failed");
    ///   without it, the collision is a warning and the local forward stays up.
    ///   That collision is not an edge case: it is the exact situation this
    ///   feature runs in. Readiness is proven by dialing the socket instead,
    ///   which is stronger than a flag anyway.
    ///
    /// `ControlPath=none` is present for lifetime hygiene: over a shared
    /// master the forward would belong to the user's long-lived connection
    /// rather than to our child, and killing our child would not be a
    /// teardown. Persistence amortizes that handshake across dictations without
    /// transferring ownership to a user's multiplexed session.
    package static func argv(
        alias: String,
        localSocketPath: String,
        remoteSocketPath: String
    ) -> [String] {
        [
            "ssh", "-N",
            "-o", "BatchMode=yes",
            "-o", "ControlPath=none",
            // The connection still inherits the ALIAS's own `Host` block, and
            // two of its settings would break this child's containment
            // (review finding 5), so both are overridden here rather than
            // hoped about:
            //   * ForkAfterAuthentication would detach ssh into a process this
            //     Process object no longer tracks — a tunnel we could neither
            //     observe nor kill, i.e. an orphan per dictation;
            //   * PermitLocalCommand + LocalCommand would run a command on THIS
            //     machine every time we open a tunnel, which is not something a
            //     dictation should be able to trigger.
            "-o", "ForkAfterAuthentication=no",
            "-o", "PermitLocalCommand=no",
            "-L", "\(localSocketPath):\(remoteSocketPath)",
            // `--` ends option parsing; the alias is validated above and cannot
            // begin with `-`, and this makes any alias that somehow did a
            // failed connection rather than a silently accepted option.
            "--", alias,
        ]
    }
}
