import Foundation

extension ClaudeRemoteEnrollmentService {
    public static let pluginListFrameBegin = "LVX_PLUGIN_LIST_BEGIN"
    public static let pluginListFrameEnd = "LVX_PLUGIN_LIST_END"
    /// A listing is a few hundred bytes per installed plugin. Anything past
    /// this is not a listing, and is never decoded.
    public static let maxPluginListBytes = 256 * 1024

    /// The script that prints the host's installed plugins as JSON inside a
    /// frame. The frame is what makes the capture readable regardless of what
    /// else the login writes to the pipe (banners, MOTD, stderr).
    package static var remotePluginListingScript: String {
        """
        set -eu
        \(Self.claudePathResolverPreamble)printf '%s\\n' \(pluginListFrameBegin)
        claude plugin list --json
        printf '\\n%s\\n' \(pluginListFrameEnd)
        """
    }

    /// The installed version of `reference` in a framed listing capture, or
    /// nil when the host has no such plugin. A user-scope entry wins over a
    /// project/local one; among equals the first entry wins. Throws when the
    /// capture carries no frame or the frame's payload is not a JSON array of
    /// entries — a host we could not read is a different verdict from a host
    /// with nothing installed, and is never reported as the latter.
    package static func installedRemotePluginVersion(
        inFramedOutput output: String,
        reference: String
    ) throws -> String? {
        guard let beginRange = output.range(of: pluginListFrameBegin),
              let endRange = output.range(
                  of: pluginListFrameEnd, range: beginRange.upperBound..<output.endIndex
              )
        else {
            throw ServiceError.runnerFailed(
                step: 0,
                command: "list remote plugins",
                message: "The host did not return a plugin listing."
            )
        }
        let payload = output[beginRange.upperBound..<endRange.lowerBound]
        let data = Data(payload.utf8)
        guard data.count <= maxPluginListBytes else {
            throw ServiceError.runnerFailed(
                step: 0,
                command: "list remote plugins",
                message: "The host's plugin listing is larger than a listing can be."
            )
        }
        guard let entries = ClaudePluginListing.entries(in: String(decoding: data, as: UTF8.self)) else {
            throw ServiceError.runnerFailed(
                step: 0,
                command: "list remote plugins",
                message: "The host's plugin listing could not be decoded."
            )
        }
        return ClaudePluginListing.entry(for: reference, in: entries)?.knownVersion
    }

    /// Install or update the remote plugin and prove the installed version.
    ///
    /// Three ssh calls, each with one job: a framed `claude plugin list
    /// --json` capture that THIS side decodes (never text-matched on the
    /// host — the human listing's shape changed once already and took every
    /// host with it), the install or update, then a second decoded listing
    /// as the read-back. The listing carries ids, versions, scopes and paths;
    /// it never carries a plugin's stored config or token (verified against
    /// Claude Code 2.1.x on 2026-09-07), so decoding it here reads nothing
    /// this process could not redact.
    public func setupRemotePlugin(
        sshHostAlias: String,
        token: String?,
        remoteForwardPort: UInt16,
        timeout: TimeInterval = defaultRemoteSetupTimeout
    ) throws -> PluginSetupOutcome {
        guard let runner else { throw ServiceError.executionNotConfigured }
        guard Self.isValidHostAlias(sshHostAlias) else { throw ServiceError.invalidHostAlias }
        let reference = Self.remotePluginReference
        let expected = Self.remotePluginVersion
        let tokenArguments = token.map {
            " --config '\(Self.tokenConfigKey)=\($0)'"
        } ?? ""

        func run(_ script: String, command: String) throws -> RunResult {
            do {
                return try runner(
                    Invocation(
                        argv: [
                            "ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--",
                            sshHostAlias, "/bin/sh", "-s",
                        ],
                        standardInput: Data(script.utf8),
                        timeout: max(timeout, 0)
                    )
                )
            } catch {
                throw sanitizedRunnerError(error, command: command)
            }
        }

        // Both halves, as in `pluginCheck`: 127 is any "command not found",
        // and the sentence is our own PATH resolver speaking.
        let firstListing = try run(Self.remotePluginListingScript, command: "list remote plugins")
        if firstListing.exitCode == 127, firstListing.message.contains("'claude' was not found") {
            return .claudeNotFound
        }

        func installedVersion(command: String, listing: RunResult? = nil) throws -> String? {
            let result = try listing ?? run(Self.remotePluginListingScript, command: command)
            guard result.succeeded else {
                let message = result.exitCode == 127
                    ? "Claude CLI was not found on the remote host. "
                        + "Install Claude Code there, or put it on the non-interactive SSH PATH."
                    : "The remote plugin listing command failed."
                throw ServiceError.commandFailed(
                    step: 0,
                    command: command,
                    exitCode: result.exitCode,
                    message: ClaudeRemoteTokenRedaction.redact(message, token: token ?? "")
                )
            }
            return try Self.installedRemotePluginVersion(
                inFramedOutput: result.message, reference: reference
            )
        }

        let before = try installedVersion(command: "list remote plugins", listing: firstListing)

        // Every branch ends in `install … --config 'port=…'`. `--config` is
        // repeatable and MERGES per key on an installed plugin, and `plugin
        // update` takes none (both verified on Claude Code 2.1.220), so that
        // line is how a host enrolled before per-Mac ports (#215) learns this
        // Mac's port without re-sending a credential. It changes no version:
        // on an installed plugin `install` exits 0 with "already installed",
        // which is why a stale plugin needs `marketplace update` then
        // `plugin update`, in that order.
        let mutation: String
        let outcome: PluginSetupOutcome
        switch before {
        case nil:
            // Decided HERE, not on the host: an absent plugin can only be
            // installed with a credential, and the update path deliberately
            // has none (the one-time enrollment token is long gone).
            // Installing tokenless would look exactly like a healthy
            // enrollment failing open, so the absence names the remedy.
            guard token != nil else {
                throw ServiceError.commandFailed(
                    step: 0,
                    command: "install remote plugin",
                    exitCode: 44,
                    message: "The plugin is not installed on the host, and this run has no token to "
                        + "give it. Rotate this host's token, then run setup again."
                )
            }
            mutation = """
                set -eu
                \(Self.claudePathResolverPreamble)claude plugin marketplace add \(Self.repositoryMarketplaceReference)
                claude plugin install \(reference)\(tokenArguments) --config '\(Self.portConfigKey)=\(remoteForwardPort)'
                """
            outcome = .installed
        case expected?:
            // Current already; the install re-applies the port config only.
            mutation = """
                set -eu
                \(Self.claudePathResolverPreamble)claude plugin install \(reference)\(tokenArguments) --config '\(Self.portConfigKey)=\(remoteForwardPort)'
                """
            outcome = .alreadyCurrent
        default:
            mutation = """
                set -eu
                \(Self.claudePathResolverPreamble)claude plugin marketplace update \(ClaudePluginAssets.marketplaceName)
                claude plugin update \(reference)
                claude plugin install \(reference)\(tokenArguments) --config '\(Self.portConfigKey)=\(remoteForwardPort)'
                """
            outcome = .updated
        }

        let mutationResult = try run(mutation, command: "install and verify remote plugin")
        guard mutationResult.succeeded else {
            let message = mutationResult.exitCode == 127
                ? "Claude CLI was not found on the remote host. "
                    + "Install Claude Code there, or put it on the non-interactive SSH PATH."
                : "The remote plugin setup command failed."
            throw ServiceError.commandFailed(
                step: 0,
                command: "install and verify remote plugin",
                exitCode: mutationResult.exitCode,
                message: ClaudeRemoteTokenRedaction.redact(message, token: token ?? "")
            )
        }

        let after = try installedVersion(command: "verify remote plugin")
        guard after == expected else {
            throw ServiceError.commandFailed(
                step: 0,
                command: "install and verify remote plugin",
                exitCode: 43,
                message: "The plugin reports version \(after ?? "none") after setup, not \(expected)."
            )
        }
        return outcome
    }
}
