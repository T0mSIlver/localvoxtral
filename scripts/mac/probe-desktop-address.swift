// Read-only probe of what Claude Desktop's focused web view says about the
// session it shows (#1065): the AX walk from the focused element up to the
// nearest AXWebArea, each element's role and class list, and the web area's
// address with every session id replaced by `<id>` plus the first 8 hex digits
// of its SHA-256, so it can be compared with a hook's environment without
// printing the id.
//
//   swift scripts/mac/probe-desktop-address.swift [delay-seconds]
//
// Run it from a terminal that has Accessibility access, then click into the
// session's chat in Claude Desktop before the delay (default 5 s) runs out.
// It posts no input and changes nothing but Electron's AXManualAccessibility,
// which the app's own reader sets before every read.
import AppKit
import ApplicationServices
import CryptoKit

let bundleID = "com.anthropic.claudefordesktop"
let delay = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 5

guard AXIsProcessTrusted() else {
    print("This terminal has no Accessibility access (System Settings > Privacy & Security > Accessibility).")
    exit(2)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    print("Claude Desktop is not running.")
    exit(2)
}
let appElement = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

print("Click into the session's chat in Claude Desktop; reading in \(Int(delay)) s.")
Thread.sleep(forTimeInterval: delay)

func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

func redacted(_ text: String) -> String {
    let pattern = try! NSRegularExpression(pattern: "(session_|local_|cse_)[A-Za-z0-9_-]+")
    var result = text
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        let range = Range(match.range, in: text)!
        let prefix = String(text[Range(match.range(at: 1), in: text)!])
        let digest = SHA256.hash(data: Data(text[range].utf8)).map { String(format: "%02x", $0) }.joined()
        result.replaceSubrange(Range(match.range, in: result)!, with: "\(prefix)<id sha256:\(digest.prefix(8))>")
    }
    return result
}

guard let focusedValue = copy(appElement, kAXFocusedUIElementAttribute) else {
    print("Claude Desktop reports no focused element. Was Desktop frontmost?")
    exit(1)
}
var element = focusedValue as! AXUIElement
for hop in 0..<60 {
    let role = copy(element, kAXRoleAttribute) as? String ?? "?"
    let classes = (copy(element, "AXDOMClassList") as? [String])?.joined(separator: " ") ?? ""
    print("\(hop) \(role) [\(classes)]")
    if role == "AXWebArea" {
        let url = copy(element, "AXURL")
        let address = (url as? URL)?.absoluteString ?? (url as? String) ?? "(no AXURL)"
        print("web area address: \(redacted(address))")
        exit(0)
    }
    guard let parent = copy(element, kAXParentAttribute) else { break }
    element = parent as! AXUIElement
}
print("No AXWebArea above the focused element.")
exit(1)
