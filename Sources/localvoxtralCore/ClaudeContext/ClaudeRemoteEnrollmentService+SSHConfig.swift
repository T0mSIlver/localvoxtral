import Foundation

extension ClaudeRemoteEnrollmentService {
    /// Whether this instance can edit `~/.ssh/config`. Production always wires
    /// the live file system; a model that cannot edit also never wrote a block
    /// through this service, so Remove Host has nothing to reverse through it
    /// and must not treat that as a failure.
    public var canEditSSHConfig: Bool { sshConfigFileSystem != nil }

    // MARK: - SSH config editing

    /// Insert or replace this host's block in an ssh config's text.
    ///
    /// Idempotent by delimiter: applying the same snippet twice yields the same
    /// text, because the second application finds and replaces the first block
    /// rather than appending a duplicate `Host` stanza (which OpenSSH would
    /// resolve as first-match-wins, so a stale duplicate above a fresh one would
    /// silently win).
    ///
    /// Everything outside the delimited block is preserved byte for byte,
    /// except in a config that mixes CRLF and LF lines, which comes back all
    /// CRLF, as the rc and hooks writers leave it. This
    /// function is the whole reason a UI could ever offer to make the edit —
    /// but it is still the caller's decision to write the result anywhere.
    public static func applySSHConfigSnippet(
        to existing: String,
        snippet: String,
        hostID: String
    ) -> String {
        let lineReader = sshConfigLineReader(hostID: hostID)
        // The file's own terminator: a CRLF config spliced with LF comes back
        // mixed, and a CRLF block appended to it is one the next read can find.
        let terminator = lineReader.lineTerminator(of: existing)
        let lines = lineReader.splitLines(existing)
        let snippetLines = lineReader.splitLines(snippet)

        guard let block = markedBlockRange(in: lines, hostID: hostID) else {
            // No block yet: append after a blank line, so our `Host` stanza can
            // never fuse onto the end of someone else's (an indented keyword
            // under the wrong `Host` is a config change they did not ask for).
            //
            // The exact spacing matters for idempotency, not for looks: the
            // replace branch below reproduces this layout byte for byte, so a
            // second apply is a no-op.
            var prefix = existing
            if !prefix.isEmpty, !prefix.hasSuffix(terminator) { prefix += terminator }
            if !prefix.isEmpty, !prefix.hasSuffix(terminator + terminator) { prefix += terminator }
            return prefix + snippetLines.joined(separator: terminator) + terminator
        }

        var result = Array(lines[..<block.lowerBound])
        result.append(contentsOf: snippetLines)
        result.append(contentsOf: lines[(block.upperBound + 1)...])
        return result.joined(separator: terminator)
    }

    /// Remove this host's block, leaving everything else untouched.
    public static func removeSSHConfigSnippet(from existing: String, hostID: String) -> String {
        let lineReader = sshConfigLineReader(hostID: hostID)
        let lines = lineReader.splitLines(existing)
        guard let block = markedBlockRange(in: lines, hostID: hostID) else { return existing }
        var result = Array(lines[..<block.lowerBound])
        result.append(contentsOf: lines[(block.upperBound + 1)...])
        return result.joined(separator: lineReader.lineTerminator(of: existing))
    }

    /// Splits a config into lines the way the rc and hooks writers do: on LF
    /// by scalar, with a CRLF line's CR stripped. Splitting on `"\n"` as a
    /// string missed every marker in a CRLF config (#678): the CR stayed on
    /// the line, and on Linux the split found no LF at all, because `"\r\n"`
    /// is one `Character`. Either way apply appended a second block.
    ///
    /// Only the line handling is shared. This writer keeps its own finding
    /// rule (first begin, first end after it) and its own remove, which
    /// leaves the separator blank line in place.
    private static func sshConfigLineReader(hostID: String) -> MarkedTextBlock {
        MarkedTextBlock(markerBegin: blockBegin(hostID: hostID), markerEnd: blockEnd(hostID: hostID))
    }

    /// Lines of the config at `data`, or nil when there is none or it is not
    /// UTF-8.
    private static func configLines(_ data: Data?, hostID: String) -> [String]? {
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        return sshConfigLineReader(hostID: hostID).splitLines(text)
    }

    /// This host's block, markers included: the first begin marker and the
    /// first end marker after it. Every reader and writer here finds it this
    /// way, so "current" and "the block a rewrite would replace" are always
    /// the same block.
    private static func markedBlockRange(in lines: [String], hostID: String) -> ClosedRange<Int>? {
        let begin = blockBegin(hostID: hostID)
        let end = blockEnd(hostID: hostID)
        guard let beginIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == begin }),
              let endIndex = lines[beginIndex...].firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == end
              })
        else { return nil }
        return beginIndex...endIndex
    }

    /// Atomically insert or replace one host's marked block in `~/.ssh/config`.
    /// The caller is responsible for obtaining the user's explicit confirmation
    /// immediately before calling this method.
    public func insertSSHConfig(snippet: String, hostID: String) throws {
        Log.claudeContext.info("Claude remote ssh config insertion requested")
        try writeSSHConfig(operation: "insertion") {
            Self.applySSHConfigSnippet(to: $0, snippet: snippet, hostID: hostID)
        }
    }

    /// Remove one marked host block through the same trust gate and atomic
    /// writer used for enrollment.
    public func removeSSHConfig(hostID: String) throws {
        Log.claudeContext.info("Claude remote ssh config removal requested")
        try writeSSHConfig(operation: "removal") {
            Self.removeSSHConfigSnippet(from: $0, hostID: hostID)
        }
    }

    private func writeSSHConfig(
        operation: String,
        transform: (String) -> String
    ) throws {
        guard let sshConfigFileSystem else {
            Log.claudeContext.error(
                "Claude remote ssh config \(operation, privacy: .public) failed: editing not configured"
            )
            throw ServiceError.sshConfigEditingNotConfigured
        }
        do {
            let state = try sshConfigFileSystem.readState()
            // Trust gate before any write decision: never write through a
            // symlink, and never into a directory another principal can also
            // write. The copy path stays available for such setups.
            guard !state.configIsSymlink, !state.directoryIsSymlink else {
                throw ServiceError.sshConfigIsSymlink
            }
            if state.directoryExists {
                guard state.directoryOwnedByCurrentUser,
                      (state.directoryPermissions ?? 0) & 0o022 == 0
                else { throw ServiceError.sshDirectoryNotTrusted }
            }
            let existing: String
            if let data = state.configData {
                guard let decoded = String(data: data, encoding: .utf8) else {
                    throw ServiceError.invalidSSHConfigEncoding
                }
                existing = decoded
            } else {
                existing = ""
            }
            let updated = transform(existing)
            if !state.directoryExists {
                try sshConfigFileSystem.createSSHDirectory(permissions: 0o700)
            }
            try sshConfigFileSystem.atomicWriteConfig(
                Data(updated.utf8),
                permissions: state.configPermissions ?? 0o600
            )
            Log.claudeContext.info(
                "Claude remote ssh config \(operation, privacy: .public) completed"
            )
        } catch {
            Log.claudeContext.error(
                "Claude remote ssh config \(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    /// Is this host's marked block exactly `snippet`, the block this build
    /// would write for it?
    ///
    /// `nil` means "cannot tell": no filesystem seam, or a config we refuse
    /// to read. Callers must treat nil as "not known to match" and
    /// regenerate, never as "fine": assuming a block is current is exactly
    /// how a plugin gets a port this Mac does not forward.
    ///
    /// The whole block, compared directive by directive. It checked the
    /// `RemoteForward` port alone until 2026-09-06, which skipped the rewrite
    /// that should have added `SendEnv LC_LVX_TTY` (review finding B1), and
    /// then the port plus `SendEnv` until 2026-09-19, which still called a
    /// block current when its forward pointed at the wrong local port or its
    /// `Host` line named another alias. The rewrite is idempotent, so a
    /// false "stale" costs one identical write, while a false "current" leaves a
    /// dead tunnel that `Update Plugin…` then skips.
    ///
    /// Read the way OpenSSH reads it: keyword case, field spacing and the
    /// optional `=` after the keyword do not count, and neither do blank or
    /// comment lines, so a commented-out directive is a missing one.
    public func sshConfigBlockIsCurrent(snippet: String, hostID: String) -> Bool? {
        guard let sshConfigFileSystem else { return nil }
        guard let state = try? sshConfigFileSystem.readState(),
              let lines = Self.configLines(state.configData, hostID: hostID)
        else { return nil }
        guard let block = Self.markedBlockRange(in: lines, hostID: hostID) else { return false }
        let begin = Self.blockBegin(hostID: hostID)
        let end = Self.blockEnd(hostID: hostID)
        return Self.directives(lines[(block.lowerBound + 1)..<block.upperBound])
            == Self.directives(Self.sshConfigLineReader(hostID: hostID).splitLines(snippet).filter {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed != begin && trimmed != end
            })
    }

    /// A block's lines as OpenSSH reads them: the keyword lowercased and
    /// split from its arguments by whitespace or one `=`, arguments split on
    /// any horizontal whitespace, blank and comment lines dropped.
    package static func directives<Lines: Sequence>(_ lines: Lines) -> [[String]]
    where Lines.Element == String {
        lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let keywordEnd = trimmed.firstIndex { $0.isWhitespace || $0 == "=" } ?? trimmed.endIndex
            var rest = trimmed[keywordEnd...].drop { $0.isWhitespace }
            if rest.first == "=" { rest = rest.dropFirst().drop { $0.isWhitespace } }
            return [trimmed[..<keywordEnd].lowercased()]
                + rest.split(whereSeparator: \.isWhitespace).map(String.init)
        }
    }

    /// What this host's block currently forwards, as three distinguishable
    /// answers — because "cannot tell", "no block yet" and "forwards 8473" lead
    /// to three different things a user should do (review finding, round 3).
    public enum SSHConfigForwardState: Sendable, Equatable {
        /// No filesystem seam, or the config could not be read.
        case unknown
        /// The config is readable and has no block for this host.
        case absent
        /// The block's first `RemoteForward` binds this port on the remote.
        case forwards(UInt16)
    }

    /// Read-only: what `~/.ssh/config` says THIS host's tunnel is, right now.
    ///
    /// The check needs this because the plan in front of the user names this
    /// Mac's CURRENT allocation, while the config on disk may still forward the
    /// port an earlier install (or the pre-#215 shared 8473) wrote. Probing the
    /// plan's port in that state reports "no tunnel is live" about a tunnel that
    /// is perfectly alive on the other port — a misdiagnosis of a setup that
    /// merely needs step 1 re-run.
    public func sshConfigForwardState(hostID: String) -> SSHConfigForwardState {
        guard let lines = markedBlockLines(hostID: hostID) else {
            return sshConfigFileSystem != nil && configIsReadable() ? .absent : .unknown
        }
        // The FIRST one wins, exactly like OpenSSH's own first-match-wins.
        for line in lines {
            if let port = forwardedPort(inLine: line) { return .forwards(port) }
        }
        return .absent
    }

    /// Whether we actually READ a config, as opposed to failing to find one.
    ///
    /// Strict on purpose, and unchanged from the behavior this refactor
    /// replaced: a config that does not exist yet, or does not decode, is
    /// "cannot tell" rather than "does not forward it". Callers regenerate on
    /// cannot-tell, and a redundant idempotent rewrite costs nothing while a
    /// wrong "already current" costs a silently dead host.
    private func configIsReadable() -> Bool {
        guard let sshConfigFileSystem,
              let state = try? sshConfigFileSystem.readState(),
              let data = state.configData
        else { return false }
        return String(data: data, encoding: .utf8) != nil
    }

    /// This host's delimited block, or nil when there is none to read.
    private func markedBlockLines(hostID: String) -> ArraySlice<String>? {
        guard let sshConfigFileSystem,
              let state = try? sshConfigFileSystem.readState(),
              let lines = Self.configLines(state.configData, hostID: hostID),
              let block = Self.markedBlockRange(in: lines, hostID: hostID)
        else { return nil }
        return lines[block]
    }

    private func forwardedPort(inLine line: String) -> UInt16? {
        let fields = line.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, fields[0] == "RemoteForward" else { return nil }
        return UInt16(fields[1])
    }
}
