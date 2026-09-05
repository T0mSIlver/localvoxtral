import Foundation

/// What the overlay says about THIS dictation's Claude Code session join.
///
/// A read-only description of the ONE answer `ClaudeSessionJoinResolver`
/// produced at dictation start — never a second resolution and never a probe.
/// Re-asking at display time would defeat the invariant the single resolution
/// exists to hold (`docs/agent/invariants.md`): every consumer must describe
/// the same session, and a badge that re-resolved could name a different one
/// than the context actually attached.
///
/// It exists because a join that silently did not happen and one that did look
/// identical today. The transcript commits either way; the only difference is
/// whether the polish call was grounded in the session the user was talking to,
/// and the user finds out by reading text that mis-transcribed the filenames
/// they just said.
///
/// Three states, not a boolean: a checkmark cannot tell a correct join from a
/// mis-join onto a session that is not the one on screen — every arm carries a
/// residual, documented where it is paid. Naming the joined workspace is what
/// makes a wrong join recognizable at a glance, and a wrong join is worse than
/// none.
enum OverlayClaudeJoinBadge: Equatable, Sendable {
    /// Nothing to say, so nothing is shown: neither context feature is on, or
    /// the app knows of no session that could have joined. Silence is the
    /// honest answer rather than a reassuring one — a user who does not run
    /// Claude Code must not be told about a join that was never attempted.
    case hidden
    /// This dictation is grounded in the named workspace's session.
    case joined(label: String)
    /// Live sessions exist and none of them attached. The state the whole badge
    /// is for: today this is indistinguishable from a working setup until you
    /// read the committed text.
    case unjoined
}

extension OverlayClaudeJoinBadge {
    /// Longest workspace label the header pill renders. The pill shares one
    /// header row with the phase title and the "Polished" badge, so the label
    /// is a name to recognize, not a path to read.
    static let maximumLabelLength = 24

    /// Shown when a join resolved for a session that never reported a cwd. The
    /// join is still real — it grounds the prompt — so the badge must not fall
    /// back to `.unjoined` and call a working setup broken.
    static let unnamedWorkspaceLabel = "Claude session"

    /// Derives the badge from this dictation's resolved join.
    ///
    /// - Parameters:
    ///   - join: the resolved join, or nil when no arm attached.
    ///   - contextFeatureEnabled: whether either context feature is on — the
    ///     SAME condition `resolveClaudeSessionJoin` gates on. Gating the badge
    ///     on the repo setting alone would hide a real join resolved for screen
    ///     attachment, which is a join the user cares about just as much.
    ///   - liveSessionsExist: whether the registry currently holds any session.
    ///     A closure, and evaluated only on the path that needs it: a resolved
    ///     join already proves a session exists, and the registry is behind a
    ///     lock every dictation start is already contending for.
    static func resolve(
        join: ClaudeSessionJoin?,
        contextFeatureEnabled: Bool,
        liveSessionsExist: () -> Bool
    ) -> OverlayClaudeJoinBadge {
        guard contextFeatureEnabled else { return .hidden }
        if let join {
            let name = join.snapshot.workspace?.displayName
            let label = name.flatMap(displayLabel(forWorkspaceName:)) ?? unnamedWorkspaceLabel
            return .joined(label: label)
        }
        // No join AND no session anywhere is the ordinary state of a Mac that
        // is not running Claude Code. Only a session that COULD have attached
        // makes "nothing attached" worth a pill.
        return liveSessionsExist() ? .unjoined : .hidden
    }

    /// Reduces a workspace display name to something a single-line header pill
    /// can safely render, or nil when nothing usable survives.
    ///
    /// `ClaudeWorkspaceReference.displayName` is already separator-free for a
    /// REMOTE session (`opaqueLabel` strips it to alphanumerics), but a LOCAL
    /// one is the last component of a real directory this user's own shell was
    /// sitting in, and a macOS path component forbids only `/` and NUL — a
    /// newline, a tab, or a bidi override is a legal directory name. The panel
    /// is measured from the body text alone (`OverlayLayoutMetrics`), so a
    /// label carrying a line break would draw outside the height the panel was
    /// sized for, and a bidi override would reorder the header around it.
    ///
    /// Both hazards are neutralized, but not the same way, because they occupy
    /// different amounts of space:
    /// - `.control` (Cc — newline, tab) becomes a SPACE. It sits between two
    ///   runs of text, and deleting it would glue them into one word that names
    ///   a directory the user does not have.
    /// - `.format` (Cf — bidi overrides, zero-width joiners) is DROPPED. It is
    ///   zero-width by definition, so a space in its place would invent one.
    ///
    /// Whitespace runs then collapse to a single space — which also covers the
    /// separator categories (U+2028/U+2029) — so no name can pad the pill wider
    /// than its own text.
    static func displayLabel(forWorkspaceName name: String) -> String? {
        let neutralized = String(
            String.UnicodeScalarView(
                name.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
                    switch scalar.properties.generalCategory {
                    case .format: return nil
                    case .control: return " "
                    default: return scalar
                    }
                }
            )
        )
        let collapsed = neutralized
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maximumLabelLength else { return collapsed }
        // Head-truncated: the leading characters of a directory name are the
        // identifying ones, and the ellipsis says the rest was cut rather than
        // letting a long name read as a different, shorter one.
        return String(collapsed.prefix(maximumLabelLength - 1)) + "…"
    }
}
