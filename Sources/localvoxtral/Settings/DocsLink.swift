import Foundation

/// Links from Settings into the docs site that scripts/docs-site builds. The
/// site serves each page at its repo path: docs/dictation.md is at
/// docs/dictation/, integrations/vibe/README.md at integrations/vibe/.
/// scripts/docs-site/check-app-links.py fails CI when a page or anchor linked
/// through here is missing from the built site.
enum DocsLink {
    static let base = "https://t0msilver.github.io/localvoxtral/"

    /// `path` is the page's path on the site plus an optional anchor, as in
    /// "docs/dictation/#shortcuts".
    static func page(_ path: String) -> URL {
        URL(string: base + path)!
    }
}
