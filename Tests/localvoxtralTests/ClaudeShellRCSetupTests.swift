import Foundation
import XCTest
@testable import localvoxtral

/// The rc-file editor for the plain-ssh join's one setup step.
///
/// It appends to a file the user owns and did not ask us to touch, so every
/// rule here is about not damaging it: replace rather than duplicate, remove
/// cleanly, preserve everything outside the markers byte for byte, and refuse
/// outright when the file is a symlink into someone's dotfiles repo.
final class ClaudeShellRCSetupTests: XCTestCase {
    private func snippet(_ shell: ClaudeShellKind) -> String {
        ClaudeShellRCSetup.snippet(for: shell)
    }

    // MARK: - Which shell, and which file

    func testTheLoginShellIsDetectedByBasenameFromRealPaths() {
        let cases: [(String?, ClaudeShellKind?)] = [
            ("/bin/zsh", .zsh),
            ("/bin/bash", .bash),
            ("/usr/local/bin/bash", .bash),
            ("/opt/homebrew/bin/fish", .fish),
            ("/usr/local/bin/fish", .fish),
            // Not shells this app will write POSIX (or fish) into.
            ("/bin/ksh", nil),
            ("/bin/sh", nil),
            ("/usr/bin/false", nil),
            // Not a path at all.
            ("zsh", nil),
            ("", nil),
            (nil, nil),
        ]
        for (path, expected) in cases {
            XCTAssertEqual(
                ClaudeShellKind.detect(loginShellPath: path), expected,
                "login shell \(path ?? "nil")"
            )
        }
    }

    func testTheRCFileFollowsMacOSConventionPerShell() {
        XCTAssertEqual(
            ClaudeShellRCSetup.relativeRCPath(for: .zsh) { _ in false }, ".zshrc"
        )
        XCTAssertEqual(
            ClaudeShellRCSetup.relativeRCPath(for: .fish) { _ in false },
            ".config/fish/conf.d/localvoxtral.fish"
        )
        // macOS terminals run bash as a LOGIN shell, which reads
        // `.bash_profile` and never `.bashrc` — but an account that keeps
        // everything in `.bashrc` is sourcing it from there, and appending to
        // the file they actually edit survives their next dotfile change.
        XCTAssertEqual(
            ClaudeShellRCSetup.relativeRCPath(for: .bash) { $0 == ".bash_profile" },
            ".bash_profile"
        )
        XCTAssertEqual(
            ClaudeShellRCSetup.relativeRCPath(for: .bash) { $0 == ".bashrc" }, ".bashrc"
        )
        XCTAssertEqual(
            ClaudeShellRCSetup.relativeRCPath(for: .bash) { _ in true }, ".bash_profile",
            "both present: the login shell's own file wins"
        )
        XCTAssertEqual(
            ClaudeShellRCSetup.relativeRCPath(for: .bash) { _ in false }, ".bash_profile",
            "neither present: create the one a login shell reads"
        )
    }

    // MARK: - The block itself

    func testThePOSIXBlockCarriesEveryGuardThatWasMeasured() {
        for shell in [ClaudeShellKind.zsh, .bash] {
            let text = snippet(shell)
            XCTAssertTrue(text.contains("[ -z \"${LC_LVX_TTY:-}\" ]"), "\(shell): already-set guard")
            XCTAssertTrue(text.contains("[ -z \"${SSH_TTY:-}\" ]"), "\(shell): only-on-this-Mac")
            XCTAssertTrue(
                text.contains("case \"$(tty 2>/dev/null)\" in /dev/*"),
                "\(shell): a tty-less shell prints `not a tty`, and exporting that "
                    + "poisons the already-set guard for everything downstream"
            )
            XCTAssertTrue(
                text.contains("if [ -z"),
                "\(shell): an `if` block, not an `&&` chain — the chain's status becomes "
                    + "the rc file's status and breaks `set -e` sourcing"
            )
            XCTAssertFalse(text.contains("set -gx"), "\(shell): that is fish syntax")
        }
    }

    func testTheFishBlockIsFishAndNotPOSIX() {
        let text = snippet(.fish)
        XCTAssertTrue(text.contains("set -gx LC_LVX_TTY"))
        XCTAssertTrue(text.contains("not set -q LC_LVX_TTY"))
        XCTAssertTrue(text.contains("not set -q SSH_TTY"))
        XCTAssertTrue(text.contains("string match -q -- '/dev/*'"))
        // fish has neither, and shipping either would be a syntax error in the
        // user's startup file — the exact damage this file exists to avoid.
        XCTAssertFalse(text.contains("case \""))
        XCTAssertFalse(text.contains("$(tty"))
        XCTAssertFalse(text.contains("export "))
    }

    func testEveryShellsBlockIsDelimitedByTheSameMarkers() {
        for shell in ClaudeShellKind.allCases {
            let text = snippet(shell)
            XCTAssertTrue(text.hasPrefix(ClaudeShellRCSetup.markerBegin), "\(shell)")
            XCTAssertTrue(text.hasSuffix(ClaudeShellRCSetup.markerEnd), "\(shell)")
            XCTAssertTrue(ClaudeShellRCSetup.containsBlock(text), "\(shell)")
        }
    }

    // MARK: - Apply, replace, remove

    func testApplyingToAnEmptyFileWritesJustTheBlock() {
        let result = ClaudeShellRCSetup.apply(to: "", snippet: snippet(.zsh))
        XCTAssertEqual(result, snippet(.zsh) + "\n")
    }

    func testApplyingPreservesEverythingElseAndSeparatesTheBlock() {
        let existing = "export EDITOR=vim\nalias ll='ls -la'\n"
        let result = ClaudeShellRCSetup.apply(to: existing, snippet: snippet(.zsh))
        XCTAssertTrue(result.hasPrefix(existing), "the user's own lines are untouched")
        XCTAssertTrue(result.contains(snippet(.zsh)))
        XCTAssertTrue(
            result.contains("alias ll='ls -la'\n\n" + ClaudeShellRCSetup.markerBegin),
            "a blank line before the block, so it cannot fuse onto their last line"
        )
    }

    func testApplyingTwiceIsAByteForByteNoOp() {
        // Not tidiness: two copies would run `tty` twice on every shell start,
        // forever, and the second block's guard would then see the first's
        // export and skip — silently masking a stale value.
        let once = ClaudeShellRCSetup.apply(to: "export EDITOR=vim\n", snippet: snippet(.zsh))
        let twice = ClaudeShellRCSetup.apply(to: once, snippet: snippet(.zsh))
        XCTAssertEqual(once, twice)
        XCTAssertEqual(
            twice.components(separatedBy: ClaudeShellRCSetup.markerBegin).count - 1, 1
        )
    }

    func testApplyingREPLACESAnOlderBlockRatherThanAppending() {
        let stale = """
        export EDITOR=vim
        \(ClaudeShellRCSetup.markerBegin)
        export LC_LVX_TTY="$(tty)"
        \(ClaudeShellRCSetup.markerEnd)
        alias ll='ls -la'
        """
        let result = ClaudeShellRCSetup.apply(to: stale, snippet: snippet(.zsh))
        XCTAssertFalse(
            result.contains("export LC_LVX_TTY=\"$(tty)\"\n\(ClaudeShellRCSetup.markerEnd)"),
            "the old body must be gone, or a shipped fix never reaches the user"
        )
        XCTAssertTrue(result.contains("case \"$(tty 2>/dev/null)\" in /dev/*"))
        XCTAssertTrue(result.hasPrefix("export EDITOR=vim\n"))
        XCTAssertTrue(result.hasSuffix("alias ll='ls -la'"))
        XCTAssertEqual(
            result.components(separatedBy: ClaudeShellRCSetup.markerBegin).count - 1, 1
        )
    }

    func testRemovingLeavesEverythingElseExactlyAsItWas() {
        let existing = "export EDITOR=vim\nalias ll='ls -la'\n"
        let applied = ClaudeShellRCSetup.apply(to: existing, snippet: snippet(.zsh))
        let removed = ClaudeShellRCSetup.remove(from: applied)
        XCTAssertFalse(ClaudeShellRCSetup.containsBlock(removed))
        XCTAssertTrue(removed.contains("export EDITOR=vim"))
        XCTAssertTrue(removed.contains("alias ll='ls -la'"))
    }

    func testRemovingFromAFileWithNoBlockChangesNothing() {
        let existing = "export EDITOR=vim\n"
        XCTAssertEqual(ClaudeShellRCSetup.remove(from: existing), existing)
    }

    func testAnIndentedMarkerIsStillOurBlock() {
        // Someone's formatter, or a copy-paste into an `if` — the block must
        // still be findable, or the next apply duplicates it.
        let indented = "    \(ClaudeShellRCSetup.markerBegin)\n    x=1\n    \(ClaudeShellRCSetup.markerEnd)\n"
        XCTAssertTrue(ClaudeShellRCSetup.containsBlock(indented))
        XCTAssertFalse(ClaudeShellRCSetup.containsBlock(ClaudeShellRCSetup.remove(from: indented)))
    }

    // MARK: - The writer's refusals

    private final class StubRCFileSystem: ClaudeShellRCFileSystem, @unchecked Sendable {
        var state: ClaudeShellRCState
        var written: (data: Data, permissions: UInt16)?
        var createdDirectory = false

        init(state: ClaudeShellRCState) { self.state = state }

        func readState() throws -> ClaudeShellRCState { state }
        func createDirectory(permissions: UInt16) throws { createdDirectory = true }
        func atomicWrite(_ data: Data, permissions: UInt16) throws {
            written = (data, permissions)
        }
    }

    func testWritingThroughASymlinkIsRefused() throws {
        // The case a dotfiles user actually hits: `~/.zshrc` is very often a
        // link into a repo, and an atomic rename REPLACES the link with a
        // regular file — silently detaching their setup. Refusing costs them a
        // copy-paste; writing costs them their dotfiles.
        for state in [
            ClaudeShellRCState(fileExists: true, fileIsSymlink: true),
            ClaudeShellRCState(fileExists: true, directoryIsSymlink: true),
        ] {
            let fileSystem = StubRCFileSystem(state: state)
            let writer = ClaudeShellRCWriter(fileSystem: fileSystem)
            XCTAssertThrowsError(try writer.apply(shell: .zsh)) { error in
                XCTAssertEqual(error as? ClaudeShellRCError, .isSymlink)
            }
            XCTAssertNil(fileSystem.written, "nothing may be written")
        }
    }

    func testAnUnwritableSetupIsNotConfiguredRatherThanSilent() {
        let writer = ClaudeShellRCWriter(fileSystem: nil)
        XCTAssertThrowsError(try writer.apply(shell: .zsh)) { error in
            XCTAssertEqual(error as? ClaudeShellRCError, .notConfigured)
        }
        XCTAssertNil(writer.isApplied(), "unknown, never `false`")
    }

    func testANewFileIsCreatedTightAndAnExistingOnesModeIsPreserved() throws {
        let fresh = StubRCFileSystem(state: ClaudeShellRCState(directoryExists: false))
        try ClaudeShellRCWriter(fileSystem: fresh).apply(shell: .fish)
        XCTAssertEqual(fresh.written?.permissions, 0o600, "a file WE create gets the tightest mode")
        XCTAssertTrue(fresh.createdDirectory, "fish's conf.d may not exist yet")

        let existing = StubRCFileSystem(state: ClaudeShellRCState(
            fileExists: true, data: Data("export EDITOR=vim\n".utf8), permissions: 0o644
        ))
        try ClaudeShellRCWriter(fileSystem: existing).apply(shell: .zsh)
        XCTAssertEqual(
            existing.written?.permissions, 0o644,
            "never widen and never narrow someone's own file — preserve it"
        )
    }

    func testIsAppliedReadsTheRealFileContents() throws {
        let fileSystem = StubRCFileSystem(state: ClaudeShellRCState(
            fileExists: true, data: Data("export EDITOR=vim\n".utf8), permissions: 0o644
        ))
        let writer = ClaudeShellRCWriter(fileSystem: fileSystem)
        XCTAssertEqual(writer.isApplied(), false)

        try writer.apply(shell: .zsh)
        fileSystem.state.data = fileSystem.written?.data
        XCTAssertEqual(writer.isApplied(), true)

        try writer.remove()
        fileSystem.state.data = fileSystem.written?.data
        XCTAssertEqual(writer.isApplied(), false)
    }

    func testNonUTF8ContentIsRefusedRatherThanOverwritten() {
        let fileSystem = StubRCFileSystem(state: ClaudeShellRCState(
            fileExists: true, data: Data([0xFF, 0xFE, 0x00]), permissions: 0o644
        ))
        let writer = ClaudeShellRCWriter(fileSystem: fileSystem)
        XCTAssertThrowsError(try writer.apply(shell: .zsh)) { error in
            XCTAssertEqual(error as? ClaudeShellRCError, .invalidEncoding)
        }
        XCTAssertNil(fileSystem.written)
    }

    // MARK: - Reading the login shell

    func testDSCLOutputIsParsedAndAnythingElseRefused() {
        XCTAssertEqual(ClaudeLoginShellReader.parse("UserShell: /bin/zsh\n"), "/bin/zsh")
        XCTAssertEqual(
            ClaudeLoginShellReader.parse("name: tom\nUserShell: /opt/homebrew/bin/fish"),
            "/opt/homebrew/bin/fish"
        )
        XCTAssertNil(ClaudeLoginShellReader.parse("UserShell: zsh"), "not a path")
        XCTAssertNil(ClaudeLoginShellReader.parse("No such key: UserShell\n"))
        XCTAssertNil(ClaudeLoginShellReader.parse(""))
    }

    func testTheEnvironmentIsOnlyAFallback() {
        // The app launches from the GUI, where `$SHELL` comes from launchd and
        // can be stale after a `chsh`. Directory Services is asked first.
        XCTAssertEqual(
            ClaudeLoginShellReader.loginShellPath(
                runDSCL: { "UserShell: /bin/zsh" }, environment: ["SHELL": "/bin/bash"]
            ),
            "/bin/zsh"
        )
        XCTAssertEqual(
            ClaudeLoginShellReader.loginShellPath(
                runDSCL: { nil }, environment: ["SHELL": "/bin/bash"]
            ),
            "/bin/bash"
        )
        XCTAssertNil(
            ClaudeLoginShellReader.loginShellPath(runDSCL: { nil }, environment: [:])
        )
        XCTAssertNil(
            ClaudeLoginShellReader.loginShellPath(
                runDSCL: { nil }, environment: ["SHELL": "bash"]
            ),
            "not a path"
        )
    }
}
