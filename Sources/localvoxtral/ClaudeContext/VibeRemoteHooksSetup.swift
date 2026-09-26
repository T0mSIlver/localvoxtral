import ClaudeContextWire
import Foundation

/// The files the Vibe hooks need on an enrolled ssh host, as this build ships
/// them (`integrations/vibe/remote/`).
public struct VibeRemoteHooksFiles: Sendable, Equatable {
    public var postScript: String
    public var compactScript: String
    public var hooksBlock: String

    public init(postScript: String, compactScript: String, hooksBlock: String) {
        self.postScript = postScript
        self.compactScript = compactScript
        self.hooksBlock = hooksBlock
    }

    /// The version constant `post.sh` sends as `X-Lvx-Vibe-Hooks-Version`. Read
    /// from the shipped file so there is one place it is written.
    public var version: String? {
        for line in postScript.split(separator: "\n") {
            let prefix = "\(VibeRemoteHooksVersionCodec.headerName): "
            guard line.hasPrefix(prefix) else { continue }
            let value = String(line.dropFirst(prefix.count))
            return ClaudeRemotePluginVersionCodec.isAcceptableVersion(value) ? value : nil
        }
        return nil
    }

    /// The three shipped files, from wherever `ClaudePluginAssets` finds them.
    public static func bundled() -> VibeRemoteHooksFiles? {
        func text(_ name: String) -> String? {
            ClaudePluginAssets.vibeFileURL(named: "remote/\(name)")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        guard let post = text("post.sh"), let compact = text("compact.py"), let block = text("hooks.toml")
        else { return nil }
        return VibeRemoteHooksFiles(postScript: post, compactScript: compact, hooksBlock: block)
    }
}

/// Setting up the Vibe hooks on an enrolled ssh host.
///
/// Same rules as the Claude Code plugin setup next to it: `ssh -o BatchMode=yes
/// -o ClearAllForwardings=yes -- <alias> /bin/sh -s`, the script on stdin so
/// the token never enters an argv on this Mac, a finite timeout, and every
/// error redacted before it leaves.
///
/// What differs is that Vibe has no `plugin install`, so the app writes the
/// files itself, and one of them is the USER'S `hooks.toml`. That edit is
/// computed HERE, by the same `VibeHooksBlockEditor` rules as the local
/// install, rather than reimplemented in awk on the host: the probe reads the
/// file back (base64, size-capped), the editor decides, and the mutation
/// script writes the result only if the file's checksum is still the one the
/// probe saw. The file's bytes are text to splice and nothing else: they never
/// reach a log, an alert or a verdict string.
extension ClaudeRemoteEnrollmentService {
    public enum VibeHooksOutcome: Sendable, Equatable {
        case installed
        case updated
        /// The host has no Vibe, so nothing was written. Not a failure: the
        /// host's setup run installs what it finds.
        case vibeNotFound
    }

    /// What the host looks like before a run. Internal to the flow; exposed
    /// for tests.
    struct VibeHostProbe: Equatable {
        var vibeFound = false
        var installedVersion: String?
        /// Nil when the host has no `hooks.toml`.
        var hooksText: String?
        var hooksChecksum: String?
        var refusal: String?
    }

    /// These runs move FILES: the scripts go out on stdin (about 25 KiB, plus a
    /// `hooks.toml` of up to 256 KiB), and the probe brings that file back as
    /// base64, all of which the parser needs. The standard budget (8 KiB in,
    /// 2,000 characters back) would refuse the first and truncate the second.
    static let vibeRunnerBudget = Invocation.Budget(
        standardInputBytes: 512 * 1024, outputBytes: 512 * 1024, messageCharacters: 512 * 1024
    )

    static let vibeProbeFrameBegin = "LVX_VIBE_PROBE_BEGIN"
    static let vibeProbeFrameEnd = "LVX_VIBE_PROBE_END"
    static let vibeHooksMaxBytes = 256 * 1024
    static let vibeRemoteDirectory = "$HOME/.vibe/localvoxtral/remote"

    /// `vibe` is routinely off a non-interactive ssh PATH (uv and pipx install
    /// into `~/.local/bin`).
    static let vibePathPrefix = "PATH=\"$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; export PATH\n"

    static var vibeProbeScript: String {
        """
        set -u
        \(vibePathPrefix)H="$HOME/.vibe/hooks.toml"
        D="\(vibeRemoteDirectory)"
        printf '%s\\n' \(vibeProbeFrameBegin)
        command -v vibe >/dev/null 2>&1 && echo vibe=found
        for p in "$HOME/.vibe" "$HOME/.vibe/localvoxtral" "$D" "$H" "$D/post.sh" "$D/compact.py" "$D/token" "$D/port"; do
          [ ! -L "$p" ] || echo refusal=symlink
        done
        if [ -r "$D/post.sh" ]; then
          sed -n 's/^\(VibeRemoteHooksVersionCodec.headerName): \\([0-9.]*\\)$/version=\\1/p' "$D/post.sh" | head -n 1
        fi
        if [ -e "$H" ]; then
          if [ ! -f "$H" ] || [ ! -r "$H" ]; then
            echo refusal=unreadable
          elif [ "$(wc -c <"$H" | tr -d '[:space:]')" -gt \(vibeHooksMaxBytes) ]; then
            echo refusal=too-large
          else
            echo "checksum=$(cksum <"$H" | tr ' ' ':')"
            echo "hooks=$(base64 <"$H" | tr -d '\\n')"
          fi
        fi
        printf '\\n%s\\n' \(vibeProbeFrameEnd)
        """
    }

    /// Only the lines between the frames, only known keys, each value held to
    /// its own alphabet. Anything else in the capture (a banner, stderr) is
    /// ignored.
    static func vibeProbe(inFramedOutput output: String) -> VibeHostProbe? {
        guard let begin = output.range(of: vibeProbeFrameBegin),
              let end = output.range(of: vibeProbeFrameEnd, range: begin.upperBound..<output.endIndex)
        else { return nil }
        var probe = VibeHostProbe()
        for line in output[begin.upperBound..<end.lowerBound].split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals]
            let value = String(line[line.index(after: equals)...])
            switch key {
            case "vibe": probe.vibeFound = value == "found"
            case "version":
                probe.installedVersion = ClaudeRemotePluginVersionCodec.isAcceptableVersion(value) ? value : nil
            case "refusal":
                probe.refusal = ["symlink", "unreadable", "too-large"].contains(value) ? value : "unknown"
            case "checksum":
                let allowed = CharacterSet(charactersIn: "0123456789:")
                guard value.count <= 32, value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
                probe.hooksChecksum = value
            case "hooks":
                // Bounded before AND after decoding: base64 is 4/3 of the file.
                guard value.utf8.count <= vibeHooksMaxBytes * 4 / 3 + 4,
                      let data = Data(base64Encoded: value), data.count <= vibeHooksMaxBytes,
                      let text = String(data: data, encoding: .utf8)
                else { return nil }
                probe.hooksText = text
            default: continue
            }
        }
        // `cksum` prints the byte count after the CRC, and the two lines come
        // from different tools. A host without `base64` (it is not POSIX)
        // prints a valid checksum and an EMPTY `hooks=`, which decodes to an
        // empty file: the run would then replace the user's hooks.toml with
        // our block alone and report success (GLM review, 2026-09-20). The
        // decoded size has to be the size `cksum` counted, or nothing is read.
        if probe.hooksChecksum != nil || probe.hooksText != nil {
            guard let checksum = probe.hooksChecksum, let text = probe.hooksText,
                  let size = checksum.split(separator: ":").dropFirst().first.flatMap({ Int($0) }),
                  text.utf8.count == size
            else { return nil }
        }
        return probe
    }

    /// A here-document delimiter that no line of `content` equals.
    static func heredocDelimiter(for content: String, seed: String) -> String {
        var delimiter = "LVX_EOF_\(seed)"
        let lines = Set(content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        while lines.contains(delimiter) { delimiter += "_X" }
        return delimiter
    }

    /// `cat >path <<'DELIM'` for one file, written to a temporary name and
    /// renamed, so a reader never sees half a file. The quoted delimiter makes
    /// the shell copy the body verbatim.
    static func writeFileScript(path: String, content: String, mode: String, seed: String) -> String {
        let delimiter = heredocDelimiter(for: content, seed: seed)
        let body = content.hasSuffix("\n") ? content : content + "\n"
        // The temporary name gets the same distrust as the final one: a link
        // planted there would make `cat >` write THROUGH it into whatever it
        // names (GLM review, 2026-09-20). Refuse a link, clear a leftover, and
        // create with noclobber so a name that reappears fails the redirect.
        return """
        [ ! -L "\(path).lvx-tmp" ] || exit 46
        rm -f "\(path).lvx-tmp"
        set -C
        cat >"\(path).lvx-tmp" <<'\(delimiter)'
        \(body)\(delimiter)
        set +C
        chmod \(mode) "\(path).lvx-tmp"
        mv -f "\(path).lvx-tmp" "\(path)"

        """
    }

    /// The guard every mutation starts with: no symlinks on the way, and
    /// `hooks.toml` still the file the probe read.
    static func vibeMutationPreamble(probe: VibeHostProbe) -> String {
        let unchanged = probe.hooksChecksum.map {
            "[ -f \"$H\" ] && [ \"$(cksum <\"$H\" | tr ' ' ':')\" = \"\($0)\" ] || exit 45"
        } ?? "[ ! -e \"$H\" ] || exit 45"
        return """
        set -eu
        umask 077
        H="$HOME/.vibe/hooks.toml"
        D="\(vibeRemoteDirectory)"
        for p in "$HOME/.vibe" "$HOME/.vibe/localvoxtral" "$D" "$H" "$D/post.sh" "$D/compact.py" "$D/token" "$D/port"; do
          [ ! -L "$p" ] || exit 46
        done
        \(unchanged)

        """
    }

    /// Install or update, in an order chosen so that a run dying at ANY point
    /// leaves a working install working:
    ///
    /// 1. write everything but the token (scripts, port, `hooks.toml`) — the
    ///    host's current token file keeps authenticating meanwhile;
    /// 2. read the host back and check the version and the block;
    /// 3. `beforeTokenActivation`, where the caller makes the registry trust
    ///    `token` IN ADDITION to the current one;
    /// 4. write the token file, a script of a few lines.
    ///
    /// The caller retires the old credential only after this returns. If step
    /// 4's connection dies, both tokens are trusted, so the host works whether
    /// or not the write landed.
    public func setUpRemoteVibeHooks(
        sshHostAlias: String,
        token: String,
        remoteForwardPort: UInt16,
        files: VibeRemoteHooksFiles,
        timeout: TimeInterval = defaultRemoteSetupTimeout,
        beforeTokenActivation: () throws -> Void = {}
    ) throws -> VibeHooksOutcome {
        guard let expected = files.version,
              let snippet = VibeHooksBlockEditor.remote.snippet(fromBundled: files.hooksBlock)
        else { throw vibeFailure("install Vibe hooks", 47, "This build's Vibe hook files are missing.", token) }

        let probe = try probeVibeHost(sshHostAlias: sshHostAlias, token: token, timeout: timeout)
        guard probe.vibeFound else { return .vibeNotFound }
        guard let updated = try? VibeHooksBlockEditor.remote.hooksByInstalling(
            snippet: snippet, into: probe.hooksText ?? ""
        ) else {
            throw vibeFailure(
                "install Vibe hooks", 48,
                "The host's ~/.vibe/hooks.toml needs a manual fix before the hooks can go in.", token
            )
        }

        var script = Self.vibeMutationPreamble(probe: probe)
        script += "mkdir -p \"$D\"\nchmod 700 \"$HOME/.vibe/localvoxtral\" \"$D\"\n"
        script += Self.writeFileScript(path: "$D/post.sh", content: files.postScript, mode: "700", seed: "POST")
        script += Self.writeFileScript(path: "$D/compact.py", content: files.compactScript, mode: "600", seed: "COMPACT")
        script += Self.writeFileScript(path: "$D/port", content: String(remoteForwardPort), mode: "600", seed: "PORT")
        if updated != probe.hooksText {
            // A new file is ours to create at 0600; an existing one keeps its mode.
            script += probe.hooksText == nil ? "" : "MODE=$(stat -c %a \"$H\" 2>/dev/null || stat -f %Lp \"$H\")\n"
            script += Self.writeFileScript(path: "$H", content: updated, mode: probe.hooksText == nil ? "600" : "\"$MODE\"", seed: "HOOKS")
        }
        try runVibe(script, sshHostAlias: sshHostAlias, command: "install Vibe hooks", token: token, timeout: timeout)

        let after = try probeVibeHost(sshHostAlias: sshHostAlias, token: token, timeout: timeout)
        guard after.installedVersion == expected,
              VibeHooksBlockEditor.remote.reading(of: after.hooksText ?? "", snippet: snippet) == .current
        else {
            // Nothing the host said goes into this sentence.
            throw vibeFailure(
                "verify Vibe hooks", 43,
                "The host did not report Vibe hooks version \(expected) after setup.", token
            )
        }

        try beforeTokenActivation()
        var activation = "set -eu\numask 077\nD=\"\(Self.vibeRemoteDirectory)\"\n"
        activation += "for p in \"$HOME/.vibe\" \"$HOME/.vibe/localvoxtral\" \"$D\" \"$D/token\"; do\n"
        activation += "  [ ! -L \"$p\" ] || exit 46\ndone\n"
        activation += Self.writeFileScript(path: "$D/token", content: token, mode: "600", seed: "TOKEN")
        try runVibe(activation, sshHostAlias: sshHostAlias, command: "activate Vibe hooks", token: token, timeout: timeout)
        return probe.installedVersion == nil ? .installed : .updated
    }

    /// An error whose description is the sentence the alert shows. The model's
    /// failure type keeps only `String(describing:)`, and a `ServiceError`
    /// describes itself as a Swift enum dump.
    struct VibeHostActionError: Error, CustomStringConvertible, Equatable {
        var description: String
    }

    static func describingVibeFailures(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as ServiceError {
            switch error {
            case .commandFailed(_, _, _, let message), .runnerFailed(_, _, let message),
                 .commandTimedOut(_, _, _, let message):
                throw VibeHostActionError(description: message)
            case .executionNotConfigured:
                throw VibeHostActionError(description: "Running commands over ssh is not available in this build.")
            default:
                throw VibeHostActionError(description: "The Vibe hooks action could not run.")
            }
        } catch ClaudeRemoteHostRegistry.StoreError.hostCredentialChanged {
            throw VibeHostActionError(
                description: "This host's token was rotated while the setup ran, so the new Vibe "
                    + "credential was not activated. Run the host setup again."
            )
        }
    }

    // MARK: - Plumbing

    private func probeVibeHost(sshHostAlias: String, token: String, timeout: TimeInterval) throws -> VibeHostProbe {
        let result = try runVibe(
            Self.vibeProbeScript, sshHostAlias: sshHostAlias, command: "inspect Vibe on the host",
            token: token, timeout: timeout
        )
        guard let probe = Self.vibeProbe(inFramedOutput: result.message) else {
            throw vibeFailure("inspect Vibe on the host", 42, "The host's answer could not be read.", token)
        }
        if let refusal = probe.refusal {
            let message: String
            switch refusal {
            case "symlink": message = "A path under ~/.vibe on the host is a symlink. See the docs for the manual install."
            case "too-large": message = "The host's ~/.vibe/hooks.toml is too large to edit from here."
            default: message = "The host's ~/.vibe/hooks.toml could not be read."
            }
            throw vibeFailure("inspect Vibe on the host", 46, message, token)
        }
        return probe
    }

    @discardableResult
    private func runVibe(
        _ script: String, sshHostAlias: String, command: String, token: String, timeout: TimeInterval
    ) throws -> RunResult {
        guard let runner else { throw ServiceError.executionNotConfigured }
        guard Self.isValidHostAlias(sshHostAlias) else { throw ServiceError.invalidHostAlias }
        let result: RunResult
        do {
            result = try runner(Invocation(
                argv: ["ssh", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "--", sshHostAlias, "/bin/sh", "-s"],
                standardInput: Data(script.utf8),
                timeout: max(timeout, 0),
                budget: Self.vibeRunnerBudget
            ))
        } catch {
            throw sanitizedRunnerError(error, command: command)
        }
        guard result.succeeded else {
            let message: String
            switch result.exitCode {
            case 45: message = "The host's ~/.vibe/hooks.toml changed while this was running. Nothing was written; try again."
            case 46: message = "A path under ~/.vibe on the host is a symlink. See the docs for the manual install."
            default: message = "The remote Vibe hooks command failed."
            }
            throw vibeFailure(command, result.exitCode, message, token)
        }
        return result
    }

    /// Fixed strings only. The host's output never becomes part of an error.
    private func vibeFailure(_ command: String, _ exitCode: Int32, _ message: String, _ token: String) -> ServiceError {
        .commandFailed(
            step: 0, command: command, exitCode: exitCode,
            message: ClaudeRemoteTokenRedaction.redact(message, token: token)
        )
    }
}
