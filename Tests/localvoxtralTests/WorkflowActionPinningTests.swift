import XCTest

/// Every `uses:` in `.github/workflows` must name a 40-character commit SHA.
///
/// A tag is mutable: whoever controls an action repo can repoint `v4` at new
/// code, and that code then runs on the self-hosted Mac with the signing
/// identity, the login keychain and the tier-2 TCC grants — and, in
/// `release.yml`, next to the token that publishes the DMG. A SHA is the only
/// ref an upstream push cannot move (issue #381).
///
/// The trailing `# vX.Y.Z` comment is also required: it is what makes the pin
/// readable, and what Dependabot rewrites when it proposes a bump.
///
/// Scanning is line-anchored, which bounds what it can see. A `uses:` written
/// as a single-line flow mapping (`steps: [{uses: a/b@v4}]`) is invisible to
/// it; a line that merely begins with `uses:` inside a `run: |` block fails
/// loudly instead. Both are acceptable: the repo writes neither, and the
/// second direction is the safe one.
final class WorkflowActionPinningTests: XCTestCase {
    private var workflowsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WorkflowActionPinningTests.swift
            .deletingLastPathComponent()  // localvoxtralTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent(".github/workflows")
    }

    private var workflowFiles: [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: workflowsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { $0.pathExtension == "yml" || $0.pathExtension == "yaml" }
            .sorted { $0.path < $1.path }
    }

    /// `uses: owner/repo@ref` with an optional trailing comment, in either
    /// step style: `uses:` on its own line, or the compact sequence item
    /// `- uses: …` that GitHub's own quickstart uses. Missing the compact
    /// form would make the guard silently blind to exactly the lane most
    /// likely to be pasted in from upstream docs.
    private static let usesPattern = try! NSRegularExpression(
        pattern: #"(?m)^\s*(?:-\s*)?uses:\s*(\S+)\s*(#.*)?$"#
    )

    private static let pinnedReference = try! NSRegularExpression(
        pattern: #"^[^@]+@[0-9a-f]{40}$"#
    )

    private struct Use {
        let file: String
        let line: Int
        let reference: String
        let comment: String?
    }

    /// Local (`./.github/actions/…`) actions are checked out with the repo,
    /// and container refs are a different pinning problem (a digest, not a
    /// commit) that this repo does not have; both are skipped rather than
    /// failed.
    private func actionUses(in text: String, file: String) -> [Use] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Self.usesPattern.matches(in: text, range: range).compactMap { match in
            guard let referenceRange = Range(match.range(at: 1), in: text) else { return nil }
            // YAML lets the value be quoted; the quotes are not part of the ref.
            let reference = String(text[referenceRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !reference.hasPrefix("."), !reference.hasPrefix("docker://") else { return nil }
            let comment = Range(match.range(at: 2), in: text).map { String(text[$0]) }
            let line = text[text.startIndex..<referenceRange.lowerBound]
                .filter { $0 == "\n" }.count + 1
            return Use(file: file, line: line, reference: reference, comment: comment)
        }
    }

    private func actionUses(in workflow: URL) throws -> [Use] {
        actionUses(
            in: try String(contentsOf: workflow, encoding: .utf8),
            file: workflow.lastPathComponent
        )
    }

    private func isPinned(_ use: Use) -> Bool {
        let range = NSRange(use.reference.startIndex..<use.reference.endIndex, in: use.reference)
        return Self.pinnedReference.firstMatch(in: use.reference, range: range) != nil
    }

    private func namesItsVersion(_ use: Use) -> Bool {
        (use.comment ?? "").range(of: #"#\s*v?\d"#, options: .regularExpression) != nil
    }

    func testEveryWorkflowActionIsPinnedToACommitSHA() throws {
        let uses = try workflowFiles.flatMap { try actionUses(in: $0) }
        XCTAssertFalse(uses.isEmpty, "found no `uses:` to check — the workflow scan is broken")

        for use in uses {
            XCTAssertTrue(
                isPinned(use),
                """
                \(use.file):\(use.line) uses a mutable ref: \(use.reference)
                Pin it to the COMMIT the tag names, and keep the version in a comment:
                  git ls-remote https://github.com/<owner>/<repo> \\
                    'refs/tags/<tag>' 'refs/tags/<tag>^{}' | tail -1 | cut -f1
                  uses: <owner>/<repo>@<sha> # <tag>
                """
            )
        }
    }

    func testEveryPinnedActionCarriesItsVersionComment() throws {
        let uses = try workflowFiles.flatMap { try actionUses(in: $0) }

        for use in uses {
            XCTAssertTrue(
                namesItsVersion(use),
                """
                \(use.file):\(use.line) pins \(use.reference) without naming the version.
                Append the tag the SHA came from: `uses: …@<sha> # v4.4.0`
                """
            )
        }
    }

    /// The scan itself, against the step styles a new lane can be written in.
    /// Without this, a regex that sees nothing would pass both tests above.
    func testScanSeesEveryStepStyle() throws {
        let sha = String(repeating: "a", count: 40)
        let yaml = """
        jobs:
          demo:
            steps:
              - name: Own-line style
                uses: owner/own-line@\(sha) # v1.0.0
              - uses: owner/compact@v4
              - uses: "owner/quoted@\(sha)" # v2.1.0
              - uses: owner/repo/subdir@\(sha) # v3.0.0
              - uses: ./.github/actions/local
              - uses: docker://alpine:3.20
              # - uses: owner/commented-out@v4
        """

        let uses = actionUses(in: yaml, file: "demo.yml")
        XCTAssertEqual(
            uses.map(\.reference),
            [
                "owner/own-line@\(sha)",
                "owner/compact@v4",
                "owner/quoted@\(sha)",
                "owner/repo/subdir@\(sha)",
            ],
            "the scan must see both step styles, unwrap quotes, and skip local/container/commented refs"
        )

        // The compact style is the one a guard anchored at `^\s*uses:` misses.
        let compact = try XCTUnwrap(uses.first { $0.reference == "owner/compact@v4" })
        XCTAssertFalse(isPinned(compact), "a floating tag must fail the pin check in either style")
        XCTAssertEqual(compact.line, 6)

        // A quoted, subdirectory-scoped pin is legitimate and must pass.
        for reference in ["owner/quoted@\(sha)", "owner/repo/subdir@\(sha)"] {
            let use = try XCTUnwrap(uses.first { $0.reference == reference })
            XCTAssertTrue(isPinned(use), "\(reference) is correctly pinned and must pass")
            XCTAssertTrue(namesItsVersion(use), "\(reference) names its version and must pass")
        }
    }
}
