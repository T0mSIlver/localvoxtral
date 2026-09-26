import AppKit
import ApplicationServices
import Foundation

/// Reads the address of the Claude Desktop web view that holds keyboard focus.
///
/// Defaults to abstain in tests the same way the other surface reads do: the
/// live implementation talks to another process over Accessibility, so no test
/// may reach it by forgetting an injection. Nil means "abstain" in every
/// failure mode.
@MainActor
protocol FocusedClaudeDesktopSessionURLReading {
    func focusedSessionURL(applicationPID pid: pid_t) async -> String?
}

/// What one walk up from the focused element found.
enum ClaudeDesktopWebAreaLookup: Equatable {
    /// Focus is in the primary pane's chat panel, and this is the address of
    /// the NEAREST web area above it (nil when it reported none). Only this
    /// web area is ever consulted: an outer one is the desktop shell, never a
    /// session.
    case webArea(url: String?)
    /// The nearest web area was reached from somewhere its address does not
    /// name, so it was not read.
    case outsidePrimaryChat(ClaudeDesktopFocusPlace)
    /// No web area above the focused element. On Electron this is what a
    /// not-yet-built accessibility tree looks like.
    case noWebArea
    /// Nothing focused, an element owned by another process, an AX error, or
    /// the walk ran past its hop cap.
    case unavailable
}

/// Where focus sat when the walk refused the web area's address.
enum ClaudeDesktopFocusPlace: Equatable {
    /// In the second pane of a split view. The address names the primary
    /// pane's session, never this one.
    case secondaryPane
    /// In the primary pane but outside its chat panel: the terminal, files
    /// or changes panel. The dictation is not going to the session.
    case primaryPaneOutsideChat
    /// Outside every pane: the sidebar, or the shell around the session view.
    case outsidePanes
}

/// The live reader: one walk up the AX parent chain from the focused element of
/// the Claude Desktop process, to the nearest `AXWebArea`, then its `AXURL`.
///
/// MEASURED on Claude Desktop 2.9939.2 (2026-09-26): the whole window is
/// ONE `AXWebArea` whose `AXURL` is `https://claude.ai/epitaxy/local_<uuid>`,
/// nested in the shell's `file://` web area. It holds the sidebar and the
/// panes; a split view adds a second pane inside the same web area, and the
/// address always names the session shown in the pane marked
/// `dframe-pane-primary` ("Primary pane"), whichever pane holds focus, after
/// real clicks in either one, and after "Move split view left" (the pane on
/// the left is then the primary one). No attribute anywhere in the tree names
/// the other pane's session. So the address counts only when the walk from
/// focus passes, in order, an element with the class `epitaxy-chat-panel`
/// (the session's transcript and prompt box) and then the first element
/// with the class `dframe-pane`, which must also carry
/// `dframe-pane-primary`. Focus in the secondary pane, in a pane's terminal,
/// files or changes panel, or in the sidebar is no join: either the address
/// names a different session, or the dictation is not going to a session.
/// The focused prompt box sits 22–24 parents below the web area.
/// (Claude Desktop 2.2553.1, 2026-09-18, had a web area per session; the
/// class rule refuses that layout, which no longer ships.)
///
/// - **PID-pinned.** Reached from `AXUIElementCreateApplication(pid)` and the
///   focused element's own pid is re-verified.
/// - **Bounded.** Every element gets the same short messaging timeout as the
///   terminal reads, the FIRST AX error ends the walk (a wedged app costs one
///   timeout, not one per hop), and each attempt has a total budget of
///   `attemptBudgetSeconds` checked before every hop. The hop cap alone was
///   not a bound (codex review, PR #333): an app answering each message just
///   under the timeout would have held the main actor ~13 s per attempt. With
///   the budget, two attempts plus the wait stay under ~1 s worst case.
/// - **Electron's tree is opt-in.** Chromium builds its web accessibility tree
///   only for a client that asks, and `AXManualAccessibility` is how an
///   assistive client asks. The reader sets it before every read — idempotent,
///   one message — and when the walk finds no web area at all it waits
///   `treeBuildWaitSeconds` once and reads again, so the first dictation after
///   Claude Desktop launches can still join. Setting it costs Claude Desktop the
///   memory of that tree while it runs; it is the same switch VoiceOver flips.
@MainActor
struct AXClaudeDesktopSessionURLReader: FocusedClaudeDesktopSessionURLReading {
    /// Parent hops before the walk gives up. The measured chain is 24; this
    /// leaves room for layout changes without letting a cyclic or runaway tree
    /// hold the main actor.
    static let maxHops = 64

    /// How long the one retry waits for Chromium to build its tree.
    static let treeBuildWaitSeconds: Double = 0.25

    /// Total time one walk may take. A healthy walk measured 7–39 ms; past
    /// this the attempt is abandoned as `.unavailable`. The last message in
    /// flight can still overrun by one messaging timeout.
    static let attemptBudgetSeconds: Double = 0.25

    typealias SleepFor = @Sendable (Double) async -> Void

    private let readOnce: @MainActor (pid_t) -> ClaudeDesktopWebAreaLookup
    private let sleepFor: SleepFor

    /// `readOnce` and `sleepFor` are the test seams: the walk's decision logic
    /// is `nearestWebArea`, and this type only adds the retry around it.
    init(
        readOnce: (@MainActor (pid_t) -> ClaudeDesktopWebAreaLookup)? = nil,
        sleepFor: @escaping SleepFor = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.readOnce = readOnce ?? { Self.liveRead(applicationPID: $0) }
        self.sleepFor = sleepFor
    }

    func focusedSessionURL(applicationPID pid: pid_t) async -> String? {
        var lookup = readOnce(pid)
        if lookup == .noWebArea {
            await sleepFor(Self.treeBuildWaitSeconds)
            lookup = readOnce(pid)
        }
        switch lookup {
        case .webArea(let url):
            // Shape-only, the browser reader's rule: an address is content, so
            // it is neither logged nor interpreted here.
            return AppleScriptFocusedBrowserTabURLReader.validatedURL(url)
        case .outsidePrimaryChat(let place):
            switch place {
            case .secondaryPane:
                Log.claudeContext.notice(
                    "Claude Desktop focus is in the second pane of a split view, whose session the web view's address does not name: no join"
                )
            case .primaryPaneOutsideChat:
                Log.claudeContext.notice(
                    "Claude Desktop focus is in a session's terminal, files or changes panel, not its prompt: no join"
                )
            case .outsidePanes:
                Log.claudeContext.notice(
                    "Claude Desktop focus is outside every session pane (sidebar?): no join"
                )
            }
            return nil
        case .noWebArea:
            Log.claudeContext.info(
                "Claude Desktop focus is not inside a web view (accessibility tree not built yet?)"
            )
            return nil
        case .unavailable:
            return nil
        }
    }

    /// The class of the element that holds a session's transcript and prompt
    /// box, one per pane.
    static let chatPanelClass = "epitaxy-chat-panel"
    /// The class every pane carries.
    static let paneClass = "dframe-pane"
    /// The class of the pane whose session the web area's address names.
    static let primaryPaneClass = "dframe-pane-primary"

    /// Walks from `start` up through `parent` to the nearest element whose
    /// `role` is `AXWebArea`, and reports its `url` only when the walk passed
    /// the primary pane's chat panel on the way.
    ///
    /// Generic so the rule is testable without AX. `role`, `classes`, `url`
    /// and `parent` return `.failure` for an AX error, which ends the walk as
    /// `.unavailable`; a missing parent (`.success(nil)`) is the top of the
    /// tree. `classes` is asked only of `AXGroup` elements below the first
    /// pane, since both markers are groups and nothing above that pane can
    /// change the answer. `outOfTime` is asked before every hop, and a `true`
    /// ends the walk as `.unavailable`.
    static func nearestWebArea<Element>(
        from start: Element,
        role: (Element) -> Result<String?, AXLookupError>,
        classes: (Element) -> Result<[String], AXLookupError>,
        url: (Element) -> Result<String?, AXLookupError>,
        parent: (Element) -> Result<Element?, AXLookupError>,
        outOfTime: () -> Bool = { false },
        maxHops: Int = AXClaudeDesktopSessionURLReader.maxHops
    ) -> ClaudeDesktopWebAreaLookup {
        var current = start
        var passedChatPanel = false
        // Decided at the first pane on the way up; nil below it.
        var verdict: PaneVerdict?
        for _ in 0...maxHops {
            guard !outOfTime() else { return .unavailable }
            guard case .success(let currentRole) = role(current) else { return .unavailable }
            if currentRole == "AXWebArea" {
                switch verdict {
                case .primaryChat?:
                    guard case .success(let address) = url(current) else { return .unavailable }
                    return .webArea(url: address)
                case .refused(let place)?:
                    return .outsidePrimaryChat(place)
                case nil:
                    return .outsidePrimaryChat(.outsidePanes)
                }
            }
            if verdict == nil, currentRole == "AXGroup" {
                guard case .success(let tokens) = classes(current) else { return .unavailable }
                if tokens.contains(chatPanelClass) { passedChatPanel = true }
                if tokens.contains(paneClass) {
                    if !tokens.contains(primaryPaneClass) {
                        verdict = .refused(.secondaryPane)
                    } else {
                        verdict = passedChatPanel ? .primaryChat : .refused(.primaryPaneOutsideChat)
                    }
                }
            }
            switch parent(current) {
            case .failure:
                return .unavailable
            case .success(nil):
                return .noWebArea
            case .success(let next?):
                current = next
            }
        }
        return .unavailable
    }

    private enum PaneVerdict: Equatable {
        case primaryChat
        case refused(ClaudeDesktopFocusPlace)
    }

    /// An AX read that failed with something other than "no such value".
    struct AXLookupError: Error, Equatable {}

    private static func liveRead(applicationPID pid: pid_t) -> ClaudeDesktopWebAreaLookup {
        #if DEBUG
        // Under XCTest a live read would query whatever the HOST runs.
        if TerminalTargetDetector.isRunningUnderXCTest { return .unavailable }
        #endif
        guard AXIsProcessTrusted() else { return .unavailable }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(attemptBudgetSeconds))
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, TerminalScreenAXReader.messagingTimeoutSeconds)
        _ = AXUIElementSetAttributeValue(
            appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )

        guard case .success(let focused?) = element(appElement, kAXFocusedUIElementAttribute)
        else { return .unavailable }
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(focused, &elementPID) == .success, elementPID == pid else {
            return .unavailable
        }
        return nearestWebArea(
            from: focused,
            role: { string($0, kAXRoleAttribute) },
            classes: { classList($0) },
            url: { address($0) },
            parent: { element($0, kAXParentAttribute) },
            outOfTime: { clock.now >= deadline }
        )
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> Result<AnyObject?, AXLookupError> {
        AXUIElementSetMessagingTimeout(element, TerminalScreenAXReader.messagingTimeoutSeconds)
        var value: AnyObject?
        switch AXUIElementCopyAttributeValue(element, attribute as CFString, &value) {
        case .success:
            return .success(value)
        case .noValue, .attributeUnsupported:
            return .success(nil)
        default:
            return .failure(AXLookupError())
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> Result<String?, AXLookupError> {
        copy(element, attribute).map { $0 as? String }
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> Result<AXUIElement?, AXLookupError> {
        copy(element, attribute).map { value in
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(value, to: AXUIElement.self)
        }
    }

    /// Chromium's `AXDOMClassList`: the element's class tokens, empty when it
    /// has none.
    private static func classList(_ element: AXUIElement) -> Result<[String], AXLookupError> {
        copy(element, "AXDOMClassList").map { ($0 as? [String]) ?? [] }
    }

    /// `AXURL` arrives as a CFURL from Chromium; a string is accepted too.
    private static func address(_ element: AXUIElement) -> Result<String?, AXLookupError> {
        copy(element, "AXURL").map { value in
            if let url = value as? URL { return url.absoluteString }
            return value as? String
        }
    }
}
