import XCTest

/// Docs must not reference screenshots that are not in the repo: a missing
/// `assets/*.png` renders as a broken image on GitHub and as a dead file in
/// any offline reader. An independent review of PR #284 found five such
/// references (panes whose captures had not landed yet); this test is the
/// backstop that keeps every docs-referenced asset resolvable.
///
/// Scans `README.md` and every `docs/**/*.md` for RELATIVE `assets/…png`
/// references — markdown `![…](assets/…)` and HTML `src="…"` / `srcset="…"`
/// (`../assets/…` from `docs/`) — and asserts each file exists. Absolute
/// URLs (GitHub `user-attachments`) are out of scope: they are not repo
/// files.
final class DocsReferencedAssetsTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DocsReferencedAssetsTests.swift
            .deletingLastPathComponent()  // localvoxtralTests
            .deletingLastPathComponent()  // Tests
    }

    private var markdownFiles: [URL] {
        var files = [repoRoot.appendingPathComponent("README.md")]
        let docsRoot = repoRoot.appendingPathComponent("docs")
        if let enumerator = FileManager.default.enumerator(
            at: docsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension == "md" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Relative `assets/…png` paths, as markdown and HTML write them: a `(`
    /// or `"` immediately before the path keeps GitHub's absolute
    /// `user-attachments/assets/…` URLs out of the match.
    private static let assetReferencePattern = try! NSRegularExpression(
        pattern: #"[\("]((?:\.\./)*assets/[^)"'\s]+\.png)"#
    )

    private func referencedPNGPaths(in markdown: String) -> [String] {
        let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        return Self.assetReferencePattern.matches(in: markdown, range: range)
            .compactMap { match in
                Range(match.range(at: 1), in: markdown).map { String(markdown[$0]) }
            }
    }

    func testEveryPNGReferencedFromDocsExistsInAssets() throws {
        var missing: [(file: String, path: String)] = []
        for markdownURL in markdownFiles {
            let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
            for path in referencedPNGPaths(in: markdown) {
                // Resolve `../assets/…` against the file's directory, exactly
                // as a renderer would.
                let resolved = URL(fileURLWithPath: path, relativeTo: markdownURL.deletingLastPathComponent())
                if !FileManager.default.fileExists(atPath: resolved.path) {
                    missing.append((markdownURL.lastPathComponent, path))
                }
            }
        }
        XCTAssertTrue(
            missing.isEmpty,
            """
            Docs reference assets/*.png files that are not in the repo: \
            \(missing.map { "\($0.file) -> \($0.path)" }.joined(separator: ", ")). \
            Docs must not reference files that do not exist; capture the pane \
            (scripts/capture-readme-assets.sh or the capture-assets.yml \
            workflow) and commit the PNG, or drop the reference.
            """
        )
    }

    /// The scan itself must have teeth: the current docs reference a
    /// nonzero set of PNGs, so a regex regression cannot pass vacuously.
    func testTheScanFindsReferencedPNGs() throws {
        var allReferenced: Set<String> = []
        for markdownURL in markdownFiles {
            let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
            allReferenced.formUnion(referencedPNGPaths(in: markdown))
        }
        XCTAssertFalse(
            allReferenced.isEmpty,
            "README/docs reference no assets/*.png — the reference scan stopped matching anything"
        )
        XCTAssertTrue(
            allReferenced.contains { $0.hasPrefix("../assets/settings-") || $0.hasPrefix("assets/settings-") },
            "the settings screenshots are the scan's bread and butter; they stopped matching"
        )
    }
}
