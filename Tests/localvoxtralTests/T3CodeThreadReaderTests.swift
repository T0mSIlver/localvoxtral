import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

/// The T3 Code reader (LVX-55): the address of the nearest web area counts
/// only when the walk up from the focused element passed the thread composer.
@MainActor
final class T3CodeThreadReaderTests: XCTestCase {
    private struct Node {
        var role: String?
        var url: String?
        var classes: [String] = []
        var parent: Int?
        var failsRole = false
        var failsClasses = false
    }

    private func walk(_ nodes: [Node], from start: Int) -> T3CodeWebAreaLookup {
        typealias Failure = AXClaudeDesktopSessionURLReader.AXLookupError
        return AXT3CodeThreadURLReader.nearestWebArea(
            from: start,
            role: { nodes[$0].failsRole ? .failure(Failure()) : .success(nodes[$0].role) },
            classes: { nodes[$0].failsClasses ? .failure(Failure()) : .success(nodes[$0].classes) },
            url: { .success(nodes[$0].url) },
            parent: { .success(nodes[$0].parent) }
        )
    }

    /// T3 Code's window cut down to what the rule reads: the composer in the
    /// thread view, the integrated terminal and the sidebar in the same web
    /// area, and the integrated browser as a web area of its own.
    private enum Window {
        static let address = "t3code://app/#/env/1ee24371-ab04-46f6-9d0e-4a845f8ee58f"
        static let composer = 0
        static let terminal = 3
        static let sidebarRow = 5
        static let browserField = 6
        static let nodes = [
            // 0–1: the composer (contenteditable) and its form.
            Node(role: "AXTextArea", classes: ["composer-tiptap", "-m-1", "block"], parent: 1),
            Node(role: "AXGroup", classes: ["relative"], parent: 2),
            // 2: the app's web area.
            Node(role: "AXWebArea", url: address, parent: 8),
            // 3–4: the integrated terminal.
            Node(role: "AXTextArea", classes: ["xterm-helper-textarea"], parent: 4),
            Node(role: "AXGroup", classes: ["xterm"], parent: 2),
            // 5: a sidebar row.
            Node(role: "AXButton", parent: 2),
            // 6–7: a page in the integrated browser, its own web area.
            Node(role: "AXTextField", classes: ["composer-tiptap"], parent: 7),
            Node(role: "AXWebArea", url: "https://example.com/#/env/1ee24371", parent: 8),
            Node(role: "AXWindow", parent: nil),
        ]
    }

    func testFocusInTheComposerReadsTheThreadAddress() {
        XCTAssertEqual(walk(Window.nodes, from: Window.composer), .webArea(url: Window.address))
    }

    func testFocusInTheTerminalOrSidebarIsNotTheComposer() {
        XCTAssertEqual(walk(Window.nodes, from: Window.terminal), .outsideComposer)
        XCTAssertEqual(walk(Window.nodes, from: Window.sidebarRow), .outsideComposer)
    }

    /// A page in T3's browser may carry the class; the nearest web area is
    /// that page's, and its address never parses as a thread.
    func testTheIntegratedBrowserReadsItsOwnAddress() {
        let lookup = walk(Window.nodes, from: Window.browserField)
        XCTAssertEqual(lookup, .webArea(url: "https://example.com/#/env/1ee24371"))
        XCTAssertNil(T3CodeThreadURL.threadID(inWebAreaURL: "https://example.com/#/env/1ee24371"))
    }

    func testNoWebAreaAndAXErrors() {
        XCTAssertEqual(walk([Node(role: "AXTextArea", classes: ["composer-tiptap"])], from: 0), .noWebArea)
        XCTAssertEqual(walk([Node(role: "AXTextArea", failsRole: true)], from: 0), .unavailable)
        XCTAssertEqual(walk([Node(role: "AXTextArea", parent: nil, failsClasses: true)], from: 0), .unavailable)
    }

    // MARK: - The read

    private final class Calls: @unchecked Sendable {
        var reads = 0
        var sleeps: [Double] = []
    }

    private func reader(_ results: [T3CodeWebAreaLookup], calls: Calls) -> AXT3CodeThreadURLReader {
        AXT3CodeThreadURLReader(
            readOnce: { _ in
                defer { calls.reads += 1 }
                return results[min(calls.reads, results.count - 1)]
            },
            sleepFor: { calls.sleeps.append($0) }
        )
    }

    func testEachLookupBecomesItsRead() async {
        let cases: [([T3CodeWebAreaLookup], T3CodeFocusRead, Int)] = [
            ([.webArea(url: Window.address)], .address(Window.address), 1),
            ([.noWebArea, .webArea(url: Window.address)], .address(Window.address), 2),
            ([.noWebArea], .refused(.noWebView), 2),
            ([.outsideComposer], .refused(.outsideComposer), 1),
            ([.unavailable], .refused(.unavailable), 1),
            ([.webArea(url: nil)], .refused(.unavailable), 1),
            ([.webArea(url: "t3code://app/#/a b")], .refused(.unavailable), 1),
        ]
        for (lookups, expected, reads) in cases {
            let calls = Calls()
            let read = await reader(lookups, calls: calls).focusedThreadURL(applicationPID: 1)
            XCTAssertEqual(read, expected, "\(lookups)")
            XCTAssertEqual(calls.reads, reads, "\(lookups)")
        }
    }

    // MARK: - Polish profile

    /// A joined T3 thread is an agent's prompt; T3 Code with no join keeps
    /// the standard profile, and the toggle still rules.
    func testAJoinedThreadGetsTheAgentPolishProfile() {
        let settings = makeSettings()
        settings.agentPolishProfileEnabled = true
        let snapshot = ClaudeSessionSnapshot(
            sessionID: "s1", origin: .localAuthenticated(peerUID: 501), firstSeen: Date(timeIntervalSince1970: 0)
        )
        let join = ClaudeSessionJoin(
            target: TerminalScreenTarget(pid: 1, bundleID: T3CodeAllowlist.bundleID),
            snapshot: snapshot, windowID: nil, mechanism: .t3Thread,
            t3Thread: ClaudeT3ThreadBinding(t3ThreadID: "t")
        )
        let bundleID = T3CodeAllowlist.bundleID
        XCTAssertEqual(
            StopCommitCoordinator.polishProfile(forTargetBundleID: bundleID, claudeJoin: join, settings: settings),
            .agent
        )
        XCTAssertEqual(
            StopCommitCoordinator.polishProfile(forTargetBundleID: bundleID, claudeJoin: nil, settings: settings),
            .standard
        )
        settings.agentPolishProfileEnabled = false
        XCTAssertEqual(
            StopCommitCoordinator.polishProfile(forTargetBundleID: bundleID, claudeJoin: join, settings: settings),
            .standard
        )
    }
}
