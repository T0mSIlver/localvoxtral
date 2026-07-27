// Shared AX probe for the macOS GUI drills (scripts/ui-smoke.sh and
// scripts/capture-readme-assets.sh). Run it with `swift scripts/lib/ax-probe.swift`.
//
// It talks to the accessibility C API directly rather than through System
// Events: the AppleScript walk never compiled against this SwiftUI window
// (error -2741, issue #72) and `entire contents of window 1` returns 0 elements
// on the macOS 26 runner while the AX API sees the whole tree.
//
// Usage:
//   ax-probe.swift <pid> --find <needle> [--scope <ax-identifier>]
//                        [--timeout <seconds>] [--dump-on-fail]
//   ax-probe.swift <pid> --press <ax-identifier> [--title <fallback-title>]
//                        [--timeout <seconds>] [--dump-on-fail]
//   ax-probe.swift <pid> --dump
//
// --find   polls the app's windows until <needle> appears in a text-bearing
//          element, optionally restricted to the subtree of the element whose
//          AXIdentifier is <scope>. Scoping is not cosmetic: sidebar row labels
//          are AXStaticText, so an unscoped needle could be satisfied by the
//          navigation chrome without the pane ever rendering. When the
//          identifier does not surface, the scope falls back to the window's
//          first AXScrollArea (still outside the navigation chrome) and the
//          success line says which route matched.
// --press  finds the element whose AXIdentifier is <ax-identifier> and sends it
//          AXPress. With --title, an AXButton whose title/description matches is
//          accepted as a fallback when SwiftUI did not surface the identifier;
//          the route actually taken is printed, so the log answers the question.
//
// Exit codes: 0 success, 1 the probe failed, 2 usage error.

import ApplicationServices
import Foundation

let arguments = CommandLine.arguments

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func usage() -> Never {
    fail(
        """
        usage:
          ax-probe.swift <pid> --find <needle> [--scope <ax-identifier>] [--timeout <seconds>] [--dump-on-fail]
          ax-probe.swift <pid> --press <ax-identifier> [--title <fallback-title>] [--timeout <seconds>] [--dump-on-fail]
          ax-probe.swift <pid> --dump
        """,
        code: 2
    )
}

guard arguments.count >= 3, let pid = Int32(arguments[1]) else { usage() }

var needle: String?
var pressIdentifier: String?
var fallbackTitle: String?
var scopeIdentifier: String?
var timeoutSeconds: Double = 10
var dumpOnFail = false
var dumpOnly = false

var index = 2
while index < arguments.count {
    let flag = arguments[index]
    switch flag {
    case "--dump-on-fail":
        dumpOnFail = true
    case "--dump":
        dumpOnly = true
    default:
        guard index + 1 < arguments.count else { usage() }
        let value = arguments[index + 1]
        index += 1
        switch flag {
        case "--find": needle = value
        case "--press": pressIdentifier = value
        case "--title": fallbackTitle = value
        case "--scope": scopeIdentifier = value
        case "--timeout":
            guard let parsed = Double(value) else { usage() }
            timeoutSeconds = parsed
        default: usage()
        }
    }
    index += 1
}

let application = AXUIElementCreateApplication(pid)

func copyAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        ? value : nil
}

func windows() -> [AXUIElement] {
    (copyAttribute(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

struct ElementText {
    let role: String
    let title: String
    let value: String
    let desc: String
    let identifier: String
}

func texts(_ element: AXUIElement) -> ElementText {
    let role = copyAttribute(element, kAXRoleAttribute) as? String ?? "?"
    let title = copyAttribute(element, kAXTitleAttribute) as? String ?? ""
    let desc = copyAttribute(element, kAXDescriptionAttribute) as? String ?? ""
    // Spelled literally: the AXIdentifier constant is not exported by every
    // SDK generation this drill has to build against.
    let identifier = copyAttribute(element, "AXIdentifier") as? String ?? ""
    var value = ""
    if let raw = copyAttribute(element, kAXValueAttribute) { value = String(describing: raw) }
    return ElementText(role: role, title: title, value: value, desc: desc, identifier: identifier)
}

// Only text-bearing roles count as visible content: control titles (buttons,
// tab rows) exist regardless of which pane is rendered.
let textRoles: Set<String> = ["AXStaticText", "AXTextField", "AXTextArea"]

func containsNeedle(
    _ element: AXUIElement, _ needle: String, depth: Int, budget: inout Int
) -> Bool {
    if depth > 40 || budget <= 0 { return false }
    budget -= 1
    let text = texts(element)
    if textRoles.contains(text.role),
        text.title.contains(needle) || text.value.contains(needle)
            || text.desc.contains(needle)
    {
        return true
    }
    for child in children(element) {
        if containsNeedle(child, needle, depth: depth + 1, budget: &budget) { return true }
    }
    return false
}

func firstElement(
    in element: AXUIElement, depth: Int, budget: inout Int,
    where predicate: (ElementText) -> Bool
) -> AXUIElement? {
    if depth > 40 || budget <= 0 { return nil }
    budget -= 1
    if predicate(texts(element)) { return element }
    for child in children(element) {
        if let found = firstElement(in: child, depth: depth + 1, budget: &budget, where: predicate)
        {
            return found
        }
    }
    return nil
}

func findInWindows(where predicate: (ElementText) -> Bool) -> AXUIElement? {
    for window in windows() {
        var budget = 20000
        if let found = firstElement(in: window, depth: 0, budget: &budget, where: predicate) {
            return found
        }
    }
    return nil
}

func dump(_ element: AXUIElement, depth: Int, budget: inout Int) {
    if depth > 40 || budget <= 0 { return }
    budget -= 1
    let text = texts(element)
    let indent = String(repeating: "  ", count: depth)
    print(
        "\(indent)\(text.role) id=\(text.identifier.prefix(60)) "
            + "title=\(text.title.prefix(60)) value=\(text.value.prefix(100)) "
            + "desc=\(text.desc.prefix(60))"
    )
    for child in children(element) {
        dump(child, depth: depth + 1, budget: &budget)
    }
}

func dumpWindows(_ headline: String) {
    let allWindows = windows()
    print("AXPROBE: \(headline); windows=\(allWindows.count)")
    for (index, window) in allWindows.enumerated() {
        print("AXPROBE: === window \(index) ===")
        var budget = 8000
        dump(window, depth: 0, budget: &budget)
    }
}

if dumpOnly {
    dumpWindows("tree dump requested")
    exit(0)
}

let deadline = Date().addingTimeInterval(timeoutSeconds)

if let pressIdentifier {
    repeat {
        if let element = findInWindows(where: { $0.identifier == pressIdentifier }) {
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                print("AXPROBE: pressed \"\(pressIdentifier)\" via AXIdentifier.")
                exit(0)
            }
        }
        if let fallbackTitle,
            let element = findInWindows(where: {
                $0.role == "AXButton" && ($0.title == fallbackTitle || $0.desc == fallbackTitle)
            })
        {
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                print(
                    "AXPROBE: pressed \"\(fallbackTitle)\" via AXTitle fallback "
                        + "(AXIdentifier \"\(pressIdentifier)\" did not surface)."
                )
                exit(0)
            }
        }
        usleep(250_000)
    } while Date() < deadline

    if dumpOnFail {
        dumpWindows(
            "could not press \"\(pressIdentifier)\" "
                + "(fallback title: \(fallbackTitle ?? "none")) after \(timeoutSeconds)s")
    }
    exit(1)
}

guard let needle else { usage() }

func subtreeContains(_ element: AXUIElement, _ needle: String) -> Bool {
    var budget = 20000
    return containsNeedle(element, needle, depth: 0, budget: &budget)
}

repeat {
    if let scopeIdentifier {
        if let scope = findInWindows(where: { $0.identifier == scopeIdentifier }) {
            if subtreeContains(scope, needle) {
                print("AXPROBE: \"\(needle)\" found inside AXIdentifier \"\(scopeIdentifier)\".")
                exit(0)
            }
        } else if let scrollArea = findInWindows(where: { $0.role == "AXScrollArea" }) {
            // The identifier did not surface. Fall back to the window's first
            // AXScrollArea, which keeps the assertion honest: the pane is the
            // only scrolling region in the Settings window, and the navigation
            // chrome (sidebar rows, pane header) sits OUTSIDE it, so a sidebar
            // label still cannot satisfy a pane assertion.
            if subtreeContains(scrollArea, needle) {
                print(
                    "AXPROBE: \"\(needle)\" found inside the window's first AXScrollArea "
                        + "(AXIdentifier \"\(scopeIdentifier)\" did not surface)."
                )
                exit(0)
            }
        }
    } else {
        for window in windows() where subtreeContains(window, needle) {
            exit(0)
        }
    }
    usleep(250_000)
} while Date() < deadline

if dumpOnFail {
    let scopeNote = scopeIdentifier.map { " within scope \"\($0)\"" } ?? ""
    dumpWindows("needle \"\(needle)\"\(scopeNote) not visible after \(timeoutSeconds)s")
}
exit(1)
