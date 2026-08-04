import Foundation
import Synchronization
import XCTest
@testable import localvoxtral

/// The per-terminal focused-TTY reader. Each supported terminal gets its own
/// AppleScript chain, but the validation and abstain-on-anything behavior are
/// one implementation — these tests pin both, without ever executing real
/// AppleScript (the first Apple event raises the Automation consent sheet).
@MainActor
final class AppleScriptTerminalTTYReaderTests: XCTestCase {
    private let supportedBundles = [
        TerminalScreenAllowlist.ghosttyBundleID,
        TerminalScreenAllowlist.iterm2BundleID,
        TerminalScreenAllowlist.appleTerminalBundleID,
    ]

    // MARK: - Script sources

    /// The chains are the reviewed, per-terminal facts of this feature:
    /// Ghostty ≥ 1.4's focused split, iTerm2's current (focused) session of
    /// the current (key) window, Terminal.app's selected tab (sdef-confirmed
    /// `tty`, code `ttty`). Each is bounded and addressed by exact bundle id.
    func testScriptSourceNamesTheDocumentedChainPerTerminal() throws {
        let cases: [(String, String)] = [
            (
                TerminalScreenAllowlist.ghosttyBundleID,
                "get tty of focused terminal of selected tab of front window"
            ),
            (
                TerminalScreenAllowlist.iterm2BundleID,
                "get tty of current session of current window"
            ),
            (
                TerminalScreenAllowlist.appleTerminalBundleID,
                "get tty of selected tab of front window"
            ),
        ]
        for (bundleID, chain) in cases {
            let source = try XCTUnwrap(
                AppleScriptTerminalTTYReader.scriptSource(forBundleID: bundleID)
            )
            XCTAssertTrue(source.contains(chain), "\(bundleID) must ask: \(chain)")
            XCTAssertTrue(
                source.contains("tell application id \"\(bundleID)\""),
                "\(bundleID) must be addressed by exact bundle id"
            )
            XCTAssertTrue(
                source.contains("with timeout of 1 second"),
                "\(bundleID)'s reply must be bounded"
            )
        }
    }

    /// macOS dismisses the TCC Automation consent sheet the moment the pending
    /// Apple event times out (field bug 2026-07-22: the iTerm2 prompt vanished
    /// after the read script's 1 s timeout, before the user could answer). The
    /// consent probe must therefore ask the same question under a timeout long
    /// enough for a human to answer the sheet.
    func testConsentPrewarmScriptGivesTheUserTimeToAnswerTheSheet() throws {
        for bundleID in TerminalScreenAllowlist.appleEventBundleIDs {
            let readSource = try XCTUnwrap(
                AppleScriptTerminalTTYReader.scriptSource(forBundleID: bundleID)
            )
            let prewarmSource = try XCTUnwrap(
                AppleScriptTerminalTTYReader.consentPrewarmScriptSource(forBundleID: bundleID)
            )
            XCTAssertTrue(
                prewarmSource.contains("with timeout of 600 seconds"),
                "\(bundleID)'s consent probe must outlive a human answering the sheet"
            )
            XCTAssertFalse(
                prewarmSource.contains("with timeout of 1 second"),
                "\(bundleID)'s consent probe must not present a 1-second prompt"
            )
            // Same question, same target — only the timeout differs, so a
            // grant earned by the probe covers every later read verbatim.
            XCTAssertEqual(
                readSource.replacingOccurrences(
                    of: "with timeout of 1 second", with: "with timeout of 600 seconds"
                ),
                prewarmSource,
                "\(bundleID)'s probe must ask exactly the read's question"
            )
        }
    }

    func testConsentPrewarmScriptSourceIsNilForUnsupportedBundles() {
        XCTAssertNil(
            AppleScriptTerminalTTYReader.consentPrewarmScriptSource(
                forBundleID: "net.kovidgoyal.kitty"
            )
        )
    }

    func testScriptSourceIsNilForUnsupportedBundles() {
        XCTAssertNil(AppleScriptTerminalTTYReader.scriptSource(forBundleID: "com.example.shell"))
        XCTAssertNil(AppleScriptTerminalTTYReader.scriptSource(forBundleID: ""))
        XCTAssertNil(
            AppleScriptTerminalTTYReader.scriptSource(forBundleID: "com.mitchellh.ghostty.evil"),
            "no prefix matching: an unverified channel build gets no script"
        )
    }

    /// Every Apple-event terminal has a TTY script: a bundle admitted to that
    /// route without a reader would silently lose its TTY-first join.
    ///
    /// The set is `appleEventBundleIDs`, not every supported bundle, because
    /// cmux joins over its own control socket and has no scripting dictionary
    /// at all — it does not lose a TTY join it never had, and an Apple event
    /// sent to it could only raise a consent prompt for nothing.
    func testEveryAppleEventBundleHasAScriptSource() {
        for bundleID in TerminalScreenAllowlist.appleEventBundleIDs {
            XCTAssertNotNil(
                AppleScriptTerminalTTYReader.scriptSource(forBundleID: bundleID),
                "\(bundleID) is join-supported over Apple events but has no TTY script"
            )
        }
    }

    func testSocketRouteTerminalsAreNeverSentAppleEvents() {
        for bundleID in TerminalScreenAllowlist.socketCaptureBundleIDs {
            XCTAssertFalse(
                TerminalScreenAllowlist.appleEventBundleIDs.contains(bundleID),
                "\(bundleID) answers on its own socket; an Apple event to it asks nothing"
            )
            XCTAssertNil(
                AppleScriptTerminalTTYReader.scriptSource(forBundleID: bundleID),
                "\(bundleID) has no scripting dictionary to read a TTY from"
            )
            XCTAssertNil(
                AppleScriptTerminalTTYReader.consentPrewarmScriptSource(forBundleID: bundleID)
            )
        }
    }

    // MARK: - Valid replies

    func testReaderParsesAValidTTYForEachSupportedTerminal() async {
        for bundleID in supportedBundles {
            let asked = Mutex<[String]>([])
            let reader = AppleScriptTerminalTTYReader { askedBundle in
                asked.withLock { $0.append(askedBundle) }
                return .success("/dev/ttys042")
            }
            let tty = await reader.focusedTerminalTTY(bundleID: bundleID)
            XCTAssertEqual(tty, "/dev/ttys042", "\(bundleID) must parse a plausible reply")
            XCTAssertEqual(
                asked.withLock { $0 }, [bundleID],
                "the script executed must be \(bundleID)'s own"
            )
        }
    }

    // MARK: - Abstentions

    func testReaderNeverExecutesForAnUnsupportedBundle() async {
        let executions = Mutex(0)
        let reader = AppleScriptTerminalTTYReader { _ in
            executions.withLock { $0 += 1 }
            return .success("/dev/ttys042")
        }
        let tty = await reader.focusedTerminalTTY(bundleID: "com.example.shell")
        XCTAssertNil(tty)
        XCTAssertEqual(
            executions.withLock { $0 }, 0,
            "an unsupported bundle must not be sent an Apple event"
        )
    }

    func testReaderAbstainsOnEveryAppleScriptFailureCode() async {
        // -1743: Automation denied. -1700/-1728: property not in the
        // dictionary (an older terminal build). 0: could not even compile.
        for code in [-1743, -1700, -1728, 0] {
            for bundleID in supportedBundles {
                let reader = AppleScriptTerminalTTYReader { _ in .failure(code: code) }
                let tty = await reader.focusedTerminalTTY(bundleID: bundleID)
                XCTAssertNil(tty, "\(bundleID) must abstain on AppleScript error \(code)")
            }
        }
    }

    func testReaderAbstainsOnImplausibleReplies() async {
        // nil result, empty, a bare name, a window title, an over-long value,
        // non-ASCII: none are a pty device, all must read as "no answer".
        let replies: [String?] = [
            nil,
            "",
            "ttys042",
            "~/repo — zsh",
            "/dev/tty" + String(repeating: "s", count: 64),
            "/dev/ttys00é",
        ]
        for reply in replies {
            for bundleID in supportedBundles {
                let reader = AppleScriptTerminalTTYReader { _ in .success(reply) }
                let tty = await reader.focusedTerminalTTY(bundleID: bundleID)
                XCTAssertNil(
                    tty,
                    "\(bundleID) must abstain on reply: \(reply.map { "'\($0)'" } ?? "nil")"
                )
            }
        }
    }
}
