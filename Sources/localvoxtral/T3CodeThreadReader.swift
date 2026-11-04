import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol FocusedT3CodeThreadURLReading {
    func focusedThreadURL(applicationPID pid: pid_t) async -> T3CodeFocusRead
}

/// What the walk up from T3 Code's focused element found.
enum T3CodeWebAreaLookup: Equatable {
    /// The nearest web area, reached through the thread composer.
    case webArea(url: String?)
    /// A web area reached without passing the composer.
    case outsideComposer
    case noWebArea
    case unavailable
}

/// Reads the address of the T3 Code web view whose thread composer holds
/// keyboard focus (LVX-55), over Accessibility.
///
/// T3 Code is Electron, like Claude Desktop, so the read is that reader's:
/// set `AXManualAccessibility`, take the app's focused element, walk UP to the
/// NEAREST `AXWebArea` and read its `AXURL`, waiting 250 ms once when no web
/// area exists yet. The address counts only when the walk passed the thread
/// composer, the element T3 Code classes `composer-tiptap` (read from T3
/// Code's web bundle 0.1.7-nightly.20261104: the contenteditable
/// `data-testid="composer-editor"`). Focus in T3's terminal, its integrated
/// browser (a separate web view, whose http(s) address never parses as a
/// thread), the sidebar or a dialog is no join: the dictation is not going to
/// the thread's agent. The class is UNDOCUMENTED: a T3 Code update that
/// renames it stops the arm joining, and each refusal says so.
@MainActor
struct AXT3CodeThreadURLReader: FocusedT3CodeThreadURLReading {
    static let composerClass = "composer-tiptap"

    typealias SleepFor = AXClaudeDesktopSessionURLReader.SleepFor

    private let readOnce: @MainActor (pid_t) -> T3CodeWebAreaLookup
    private let sleepFor: SleepFor

    init(
        readOnce: (@MainActor (pid_t) -> T3CodeWebAreaLookup)? = nil,
        sleepFor: @escaping SleepFor = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.readOnce = readOnce ?? { Self.liveRead(applicationPID: $0) }
        self.sleepFor = sleepFor
    }

    func focusedThreadURL(applicationPID pid: pid_t) async -> T3CodeFocusRead {
        var lookup = readOnce(pid)
        if lookup == .noWebArea {
            await sleepFor(AXClaudeDesktopSessionURLReader.treeBuildWaitSeconds)
            lookup = readOnce(pid)
        }
        switch lookup {
        case .webArea(let url):
            // Shape-only: an address is content, neither logged nor read here.
            guard let address = AppleScriptFocusedBrowserTabURLReader.validatedURL(url) else {
                return .refused(.unavailable)
            }
            return .address(address)
        case .outsideComposer:
            Log.claudeContext.notice(
                "T3 Code focus is not in a thread's composer (terminal, browser, sidebar?): no join"
            )
            return .refused(.outsideComposer)
        case .noWebArea:
            Log.claudeContext.info("T3 Code focus is not inside a web view (accessibility tree not built yet?)")
            return .refused(.noWebView)
        case .unavailable:
            return .refused(.unavailable)
        }
    }

    /// The walk, pure over its four reads so every outcome is testable.
    static func nearestWebArea<Element>(
        from start: Element,
        role: (Element) -> Result<String?, AXClaudeDesktopSessionURLReader.AXLookupError>,
        classes: (Element) -> Result<[String], AXClaudeDesktopSessionURLReader.AXLookupError>,
        url: (Element) -> Result<String?, AXClaudeDesktopSessionURLReader.AXLookupError>,
        parent: (Element) -> Result<Element?, AXClaudeDesktopSessionURLReader.AXLookupError>,
        outOfTime: () -> Bool = { false },
        maxHops: Int = AXClaudeDesktopSessionURLReader.maxHops
    ) -> T3CodeWebAreaLookup {
        var current = start
        var passedComposer = false
        for _ in 0...maxHops {
            guard !outOfTime() else { return .unavailable }
            guard case .success(let currentRole) = role(current) else { return .unavailable }
            if currentRole == "AXWebArea" {
                guard passedComposer else { return .outsideComposer }
                guard case .success(let address) = url(current) else { return .unavailable }
                return .webArea(url: address)
            }
            if !passedComposer {
                guard case .success(let tokens) = classes(current) else { return .unavailable }
                if tokens.contains(composerClass) { passedComposer = true }
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

    private static func liveRead(applicationPID pid: pid_t) -> T3CodeWebAreaLookup {
        #if DEBUG
        // Under XCTest a live read would query whatever the HOST runs.
        if TerminalTargetDetector.isRunningUnderXCTest { return .unavailable }
        #endif
        guard AXIsProcessTrusted() else { return .unavailable }
        typealias AX = AXClaudeDesktopSessionURLReader
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(AX.attemptBudgetSeconds))
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, TerminalScreenAXReader.messagingTimeoutSeconds)
        _ = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard case .success(let focused?) = AX.element(appElement, kAXFocusedUIElementAttribute)
        else { return .unavailable }
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(focused, &elementPID) == .success, elementPID == pid else {
            return .unavailable
        }
        return nearestWebArea(
            from: focused,
            role: { AX.string($0, kAXRoleAttribute) },
            classes: { AX.classList($0) },
            url: { AX.address($0) },
            parent: { AX.element($0, kAXParentAttribute) },
            outOfTime: { clock.now >= deadline }
        )
    }
}
