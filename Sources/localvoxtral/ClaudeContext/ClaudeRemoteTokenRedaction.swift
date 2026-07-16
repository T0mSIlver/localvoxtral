import Foundation

/// Scrubs a plaintext host token out of text that is about to escape.
///
/// The registry's design keeps the plaintext in exactly two places: the return
/// value of `enroll`/`rotateToken`, and the setup text the user copies. Between
/// those two points it passes through generated commands — and a generated
/// command is precisely the string that ends up in an error, an alert, a log
/// line, or a screenshot in a bug report.
///
/// This is a backstop, not a strategy. The strategy is not to put the token in
/// those strings in the first place (`SetupPlan.sshConfigSnippet` carries none;
/// `ServiceError` is redacted at the throw site). Use this wherever a string
/// that MAY contain the token crosses into something durable, and prefer
/// redacting at the boundary over trusting a caller not to log.
public enum ClaudeRemoteTokenRedaction {
    /// What a redacted token reads as. Deliberately not the same length as a
    /// token: a fixed-width mask invites someone to conclude the length is
    /// meaningful, and length is the one property of a secret that a mask should
    /// not preserve.
    public static let placeholder = "<redacted>"

    /// Replace every occurrence of `token` with `placeholder`.
    ///
    /// A short or empty token is refused rather than replaced. Redacting `""`
    /// would match at every index and turn the whole message into placeholders;
    /// redacting a 2-character token would shred unrelated text. Real tokens are
    /// 43 base64url characters, so the minimum here can never reject one — it
    /// only rejects a caller passing something that is not a token.
    public static func redact(_ text: String, token: String) -> String {
        guard token.count >= ClaudeRemoteTokenDigest.minTokenLength else { return text }
        return text.replacingOccurrences(of: token, with: placeholder)
    }

}
