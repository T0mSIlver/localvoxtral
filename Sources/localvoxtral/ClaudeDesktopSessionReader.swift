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
    /// The NEAREST web area above the focused element, and its address (nil
    /// when it reported none). Only this web area is ever consulted: an outer
    /// one is the desktop shell, never a session.
    case webArea(url: String?)
    /// No web area above the focused element. On Electron this is what a
    /// not-yet-built accessibility tree looks like.
    case noWebArea
    /// Nothing focused, an element owned by another process, an AX error, or
    /// the walk ran past its hop cap.
    case unavailable
}

/// The live reader: one walk up the AX parent chain from the focused element of
/// the Claude Desktop process, to the nearest `AXWebArea`, then its `AXURL`.
///
/// MEASURED on Claude Desktop 2.2553.1 (2026-09-18): the focused element sits
/// ~25 parents below an `AXWebArea` whose `AXURL` is
/// `https://claude.ai/epitaxy/local_<uuid>` — the focused session — and the
/// whole walk took 7–30 ms. Walking UP from focus is the rule, not searching
/// the window: Claude Desktop can show several sessions side by side, and the
/// one the user is typing into is the one that holds focus. Focus outside any
/// session's web view (the sidebar, the chat tab) is correctly no join — the
/// dictation is not going to a session.
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
    /// Parent hops before the walk gives up. The measured chain is 25; this
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
        case .noWebArea:
            Log.claudeContext.info(
                "Claude Desktop focus is not inside a web view (accessibility tree not built yet?)"
            )
            return nil
        case .unavailable:
            return nil
        }
    }

    /// Walks from `start` up through `parent` to the nearest element whose
    /// `role` is `AXWebArea`, and reports its `url`.
    ///
    /// Generic so the rule is testable without AX. `role`, `url` and `parent`
    /// return `.failure` for an AX error, which ends the walk as
    /// `.unavailable`; a missing parent (`.success(nil)`) is the top of the
    /// tree. `outOfTime` is asked before every hop, and a `true` ends the walk
    /// as `.unavailable`.
    static func nearestWebArea<Element>(
        from start: Element,
        role: (Element) -> Result<String?, AXLookupError>,
        url: (Element) -> Result<String?, AXLookupError>,
        parent: (Element) -> Result<Element?, AXLookupError>,
        outOfTime: () -> Bool = { false },
        maxHops: Int = AXClaudeDesktopSessionURLReader.maxHops
    ) -> ClaudeDesktopWebAreaLookup {
        var current = start
        for _ in 0...maxHops {
            guard !outOfTime() else { return .unavailable }
            guard case .success(let currentRole) = role(current) else { return .unavailable }
            if currentRole == "AXWebArea" {
                guard case .success(let address) = url(current) else { return .unavailable }
                return .webArea(url: address)
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

    /// `AXURL` arrives as a CFURL from Chromium; a string is accepted too.
    private static func address(_ element: AXUIElement) -> Result<String?, AXLookupError> {
        copy(element, "AXURL").map { value in
            if let url = value as? URL { return url.absoluteString }
            return value as? String
        }
    }
}
