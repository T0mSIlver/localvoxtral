import Foundation

/// Reads the Claude project thread a prompt was relayed from (#1194).
///
/// A Claude project's thread runs in a Claude Code session of its own, and
/// the project's harness writes each message it relays to that session
/// inside an envelope at the head of the prompt (MEASURED 2026-10-05 on nine
/// relayed prompts in seven thread sessions on the dev box):
///
///     <wake reason="…" current-time="…"><project id="chan_…" type="project">
///     <thread ts="cmsg_…"><message …>the user's words</message></thread>…
///
/// The `ts` attribute is the thread's id, the one Claude Desktop's project
/// page carries as `?thread=cmsg_…`. No environment variable names it, so the
/// prompt is the session side's only source, and that is reading another
/// tool's text (#1011). Only the envelope's FIRST bytes are read, up to the
/// thread tag, and they must match exactly: the harness writes them before
/// any of the user's text, so nothing typed into a thread can move or forge
/// them. A user typing the whole envelope as a prompt of their own claims a
/// thread for their own session; a second reporter of the id makes the join
/// abstain as ambiguous.
package enum ClaudeProjectThreadEnvelope {
    private static let idPrefix = "cmsg_"
    private static let maxIDCount = 128

    private static let head = try! NSRegularExpression(
        pattern: #"\A<wake(?: [a-z-]+="[^"<>]*")*>\s*<project id="chan_[A-Za-z0-9_-]{1,123}" type="project">\s*<thread ts="(cmsg_[A-Za-z0-9_-]{1,123})">"#
    )

    /// The thread id at the head of `prompt`, or nil when the prompt does not
    /// open with a project relay envelope.
    package static func threadID(inPrompt prompt: String) -> String? {
        let range = NSRange(prompt.startIndex..., in: prompt)
        guard let match = head.firstMatch(in: prompt, options: .anchored, range: range),
              let idRange = Range(match.range(at: 1), in: prompt)
        else { return nil }
        let threadID = String(prompt[idRange])
        return isThreadID(threadID) ? threadID : nil
    }

    /// `cmsg_[A-Za-z0-9_-]+`, ASCII, at most 128 characters.
    package static func isThreadID(_ candidate: String) -> Bool {
        ClaudeSessionPageURL.isIdentifier(candidate, prefix: idPrefix, maxCount: maxIDCount)
    }
}
