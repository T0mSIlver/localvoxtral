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

    /// `uses: owner/repo@ref` with an optional trailing comment. Local
    /// (`./.github/actions/…`) and container (`docker://…`) references carry no
    /// ref to pin, so they are matched and skipped rather than failed.
    private static let usesPattern = try! NSRegularExpression(
        pattern: #"(?m)^\s*uses:\s*(\S+)\s*(#.*)?$"#
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

    private func actionUses(in workflow: URL) throws -> [Use] {
        let text = try String(contentsOf: workflow, encoding: .utf8)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Self.usesPattern.matches(in: text, range: range).compactMap { match in
            guard let referenceRange = Range(match.range(at: 1), in: text) else { return nil }
            let reference = String(text[referenceRange])
            // Local and container actions are not fetched from a mutable tag.
            guard !reference.hasPrefix("."), !reference.hasPrefix("docker://") else { return nil }
            let comment = Range(match.range(at: 2), in: text).map { String(text[$0]) }
            let line = text[text.startIndex..<referenceRange.lowerBound]
                .filter { $0 == "\n" }.count + 1
            return Use(
                file: workflow.lastPathComponent,
                line: line,
                reference: reference,
                comment: comment
            )
        }
    }

    func testEveryWorkflowActionIsPinnedToACommitSHA() throws {
        let uses = try workflowFiles.flatMap { try actionUses(in: $0) }
        XCTAssertFalse(uses.isEmpty, "found no `uses:` to check — the workflow scan is broken")

        for use in uses {
            let range = NSRange(use.reference.startIndex..<use.reference.endIndex, in: use.reference)
            XCTAssertNotNil(
                Self.pinnedReference.firstMatch(in: use.reference, range: range),
                """
                \(use.file):\(use.line) uses a mutable ref: \(use.reference)
                Pin it to the tag's commit SHA and keep the version in a comment:
                  gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq .object.sha
                  uses: <owner>/<repo>@<sha> # <tag>
                """
            )
        }
    }

    func testEveryPinnedActionCarriesItsVersionComment() throws {
        let uses = try workflowFiles.flatMap { try actionUses(in: $0) }

        for use in uses {
            let comment = use.comment ?? ""
            XCTAssertTrue(
                comment.range(of: #"#\s*v?\d"#, options: .regularExpression) != nil,
                """
                \(use.file):\(use.line) pins \(use.reference) without naming the version.
                Append the tag the SHA came from: `uses: …@<sha> # v4.4.0`
                """
            )
        }
    }
}
