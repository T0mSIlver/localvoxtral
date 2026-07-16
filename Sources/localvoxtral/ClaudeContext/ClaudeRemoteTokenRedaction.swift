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

    /// Redact without knowing the token.
    ///
    /// For text whose provenance is unclear — remote command output, a caught
    /// error from some layer that never saw the plaintext. Matches the *shape*
    /// of the places a token is known to travel (`--config 'token=…'`, an
    /// `Authorization: Bearer …` header) rather than the value, because at these
    /// call sites the value is genuinely unavailable.
    ///
    /// Shape-matching is strictly weaker than value-matching: it cannot catch a
    /// token that appears bare, with no surrounding syntax. Prefer
    /// `redact(_:token:)` whenever the value is in hand.
    public static func redactKnownShapes(_ text: String) -> String {
        var result = text
        for pattern in [
            // --config 'token=…'  /  --config token=…  /  --config "token=…"
            #"(--config\s+['"]?\#(ClaudeRemoteEnrollmentService.tokenConfigKey)=)[^'"\s]+"#,
            // Authorization: Bearer …
            #"([Bb]earer\s+)[A-Za-z0-9\-_]{16,}"#,
        ] {
            result = result.replacingOccurrences(
                of: pattern,
                with: "$1\(placeholder)",
                options: [.regularExpression]
            )
        }
        return result
    }
}
