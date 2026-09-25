import Foundation
@testable import localvoxtralCore
import XCTest

final class DictationTermsFileTests: XCTestCase {
    func testTakesCodeSpansAndListItemHeads() {
        let markdown = """
        # Dictation

        Spell these the way the code does. Keep `localvoxtral` lowercase.

        - Voxtral — the speech model
        - **Claude Code**: the agent
        * herdr
        1. `speechd` and `polishd`
        2) Nemotron (the second engine)
        """
        XCTAssertEqual(
            DictationTermsFile.terms(fromMarkdown: markdown),
            ["localvoxtral", "Voxtral", "Claude Code", "herdr", "speechd", "polishd", "Nemotron"]
        )
    }

    func testIgnoresProseHeadingsAndFencedBlocks() {
        let markdown = """
        ## Formatting
        Use sentence case in commit messages and never add a trailing period.
        ```
        - notATerm
        `alsoNotATerm`
        ```
        ~~~
        - stillNotATerm
        ~~~
        - kept
        """
        XCTAssertEqual(DictationTermsFile.terms(fromMarkdown: markdown), ["kept"])
    }

    func testRejectsLinksLongItemsAndSymbolOnlySpans() {
        let markdown = """
        - [the docs](https://example.com/docs)
        - This item is a whole sentence of instructions rather than a term
        - `https://example.com`
        - `--`
        - x
        """
        XCTAssertEqual(DictationTermsFile.terms(fromMarkdown: markdown), [])
    }

    func testDedupesAndCapsTheList() {
        let items = (0..<(DictationTermsFile.maximumTerms + 50)).map { "- term\($0)" }
        let markdown = (["- term0", "- `term0`"] + items).joined(separator: "\n")
        let terms = DictationTermsFile.terms(fromMarkdown: markdown)
        XCTAssertEqual(terms.count, DictationTermsFile.maximumTerms)
        XCTAssertEqual(terms.first, "term0")
        XCTAssertEqual(Set(terms).count, terms.count)
    }

    func testReadsTheFileUnderGithub() throws {
        let root = try makeRoot()
        try write("- Voxtral\n", root: root)
        XCTAssertEqual(DictationTermsFile.read(root: root.path), ["Voxtral"])
        XCTAssertNotNil(DictationTermsFile.modificationDate(root: root.path))
    }

    func testMissingFileReadsAsEmpty() throws {
        let root = try makeRoot()
        XCTAssertEqual(DictationTermsFile.read(root: root.path), [])
        XCTAssertNil(DictationTermsFile.modificationDate(root: root.path))
    }

    func testOversizedFileIsSkippedNotTruncated() throws {
        let root = try makeRoot()
        let padding = String(repeating: "a", count: DictationTermsFile.maximumBytes)
        try write("- Voxtral\n" + padding, root: root)
        XCTAssertEqual(DictationTermsFile.read(root: root.path), [])
    }

    func testSymlinkIsRefused() throws {
        let root = try makeRoot()
        let elsewhere = root.appendingPathComponent("elsewhere.md")
        try "- Voxtral\n".write(to: elsewhere, atomically: true, encoding: .utf8)
        let github = root.appendingPathComponent(".github")
        try FileManager.default.createDirectory(at: github, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: github.appendingPathComponent("dictation.md"), withDestinationURL: elsewhere
        )
        XCTAssertEqual(DictationTermsFile.read(root: root.path), [])
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-terms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ text: String, root: URL) throws {
        let github = root.appendingPathComponent(".github")
        try FileManager.default.createDirectory(at: github, withIntermediateDirectories: true)
        try text.write(
            to: github.appendingPathComponent("dictation.md"), atomically: true, encoding: .utf8
        )
    }
}
