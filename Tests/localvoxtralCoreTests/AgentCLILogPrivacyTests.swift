import Foundation
import XCTest

@testable import localvoxtralCore

/// `localvoxtral logs` hands the unified log to a coding agent, and anyone can
/// read a `privacy: .public` value with `log show`. So no public log value may
/// hold dictated text: a transcript, a polish result, inserted text, a quick
/// capture, a prompt, screen or clipboard text (#910).
///
/// It reads every `\(…, privacy: .public)` under Sources/ and fails on one
/// whose expression names a value that holds such text, unless the
/// expression ends in a size or a case (`.count`, `.isEmpty`, `.rawValue`).
/// The names are the ones the #910 audit found holding dictated text.
final class AgentCLILogPrivacyTests: XCTestCase {
    /// Names of values that hold dictated or read text in this codebase.
    static let textNames: Set<String> = [
        "text", "rawText", "polishedText", "committedText", "finalText", "partialText", "workingText",
        "groundedWorkingText", "dictatedText", "insertedText", "inserted", "currentDictationEventText",
        "transcript", "delta", "utterance", "spokenName", "words", "hex", "payload",
        "prompt", "answer", "draft", "capture", "readme", "excerpt", "startText",
        "body", "clipboard", "content", "contents", "stdout", "stderr",
    ]

    /// Endings that reduce any value to something that is not its text.
    static let safeEndings: Set<String> = [
        "count", "isEmpty", "rawValue", "exitCode", "statusCode", "id", "kind", "relation", "state",
    ]

    /// Opt-in debug logs whose job is to show the text, each behind a switch
    /// that is off by default and has no UI. `logs` prints neither: they log
    /// at `.notice` without the join prefix.
    static let allowed: Set<String> = [
        // `defaults write com.localvoxtral.app debug.log_realtime_deltas`.
        "RealtimeDeltaLog.swift: delta.debugDescription",
        "RealtimeDeltaLog.swift: text.debugDescription",
        // The scalar-trace marker file in the config folder.
        "TextInsertionService.swift: hex",
    ]

    func testNoPublicLogValueHoldsDictatedText() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(atPath: sources.path)?.allObjects as? [String])
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 100, "Sources/ not found from \(#filePath)")

        var scanned = 0
        var findings: [String] = []
        for file in files.sorted() {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for expression in Self.publicExpressions(in: text) {
                scanned += 1
                guard Self.holdsText(expression) else { continue }
                let key = "\((file as NSString).lastPathComponent): \(expression)"
                if !Self.allowed.contains(key) { findings.append("Sources/\(file): \(expression)") }
            }
        }
        XCTAssertGreaterThan(scanned, 400, "the scan found too few public values to be reading the log calls")
        XCTAssertEqual(
            findings, [],
            "These public log values can hold dictated text. Log them `privacy: .private`, or log their `.count`."
        )
    }

    func testTheScanCatchesTextAndPassesItsSize() {
        let source = #"""
            Log.polishing.notice("polished: \(result.polishedText, privacy: .public)")
            Log.polishing.notice("length: \(result.polishedText.count, privacy: .public) mode \(mode.rawValue, privacy: .public)")
            Log.backends.error("inserted \(String(describing: session.insertedText), privacy: .public) ok")
            Log.backends.error("failed: \(error.localizedDescription, privacy: .public)")
            Log.backends.notice("mode \(drafts ? "first draft" : "agent only", privacy: .public)")
            """#
        let expressions = Self.publicExpressions(in: source)
        XCTAssertEqual(expressions, [
            "result.polishedText", "result.polishedText.count", "mode.rawValue",
            "String(describing: session.insertedText)", "error.localizedDescription",
            #"drafts ? "first draft" : "agent only""#,
        ])
        XCTAssertEqual(expressions.filter(Self.holdsText), [
            "result.polishedText", "String(describing: session.insertedText)",
        ])
        // A literal's words are constants; a value interpolated into one is not.
        XCTAssertTrue(Self.holdsText(#""\(prefix) " + draft + " \(suffix)""#))
        XCTAssertTrue(Self.holdsText(#""quoted: \(draft)""#))
    }

    /// A polish backend's error body can quote the request, so the three
    /// polish failure lines log it private and only the status public.
    func testAPolishErrorLogsItsStatusPublicAndItsBodyNot() {
        let error = LLMPolishingError.requestFailed(statusCode: 422, body: #"{"input":"the words I dictated"}"#)
        XCTAssertEqual(LLMPolishingError.publicLogDescription(of: error), "LLM request failed (HTTP 422).")
        XCTAssertEqual(
            LLMPolishingError.publicLogDescription(of: LLMPolishingError.timedOut(afterSeconds: 30)),
            "LLM request timed out after 30 s."
        )
    }

    /// The expression of every `\(…, privacy: .public)`, parentheses
    /// balanced, so a call inside the interpolation stays whole.
    static func publicExpressions(in source: String) -> [String] {
        let marker = Array(", privacy: .public)")
        let characters = Array(source)
        var expressions: [String] = []
        var index = 0
        while index + marker.count <= characters.count {
            guard Array(characters[index..<(index + marker.count)]) == marker else {
                index += 1
                continue
            }
            // Walk back to the `\(` that opens this interpolation.
            var depth = 0
            var start = index - 1
            while start > 0 {
                let character = characters[start]
                if character == ")" { depth += 1 }
                if character == "(" {
                    if depth == 0 { break }
                    depth -= 1
                }
                start -= 1
            }
            if start > 0, characters[start - 1] == "\\" {
                expressions.append(String(characters[(start + 1)..<index]).trimmingCharacters(in: .whitespaces))
            }
            index += marker.count
        }
        return expressions
    }

    /// The expression with the constant text of its string literals blanked,
    /// since in `flag ? "draft" : "agent only"` the words are not values. An
    /// interpolation inside a literal stays: it names one. A literal nested
    /// in an interpolation also stays, which errs toward a finding.
    static func withoutLiteralText(_ expression: String) -> String {
        var output = ""
        var inLiteral = false
        var escaped = false
        var parenDepth = 0
        var openInterpolations: [Int] = []  // paren depth each `\(` opened at
        for character in expression {
            if inLiteral, openInterpolations.isEmpty {
                if escaped, character == "(" {
                    openInterpolations.append(parenDepth)
                    parenDepth += 1
                    output.append(" ")
                } else if !escaped, character == "\"" {
                    inLiteral = false
                    output.append(" ")
                }
                escaped = !escaped && character == "\\"
                continue
            }
            switch character {
            case "\"":
                inLiteral = true
                output.append(" ")
                continue
            case "(":
                parenDepth += 1
            case ")":
                parenDepth -= 1
                if openInterpolations.last == parenDepth {
                    openInterpolations.removeLast()
                    output.append(" ")
                    continue
                }
            default:
                break
            }
            output.append(character)
        }
        return output
    }

    static func holdsText(_ expression: String) -> Bool {
        let identifiers = withoutLiteralText(expression).split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
        guard identifiers.contains(where: textNames.contains) else { return false }
        return !safeEndings.contains(identifiers.last ?? "")
    }
}
