import Foundation
import XCTest

@testable import localvoxtralCore

/// Replays labelled captures through the production router (#730) and
/// prints the scoreboard: the right-project rate, the catch-all count and
/// the captures sent to a wrong project. Spends real tokens, so it runs only
/// through `scripts/linux/quick-capture-replay.sh`, on Linux.
///
/// Inputs (paths, from the script's flags):
/// - `QC_CAPTURES`: JSON lines `{"id", "expected", "text"}`; `expected` is a
///   project name, or `inbox` for the catch-all. A name missing from the
///   project set expects the catch-all.
/// - `QC_PROJECTS`: `[{"key", "name", "terms", "userLine"?}]`; a key that is
///   a path gets its README read, as the app does for a local checkout.
/// - `QC_JEV_HOST` + `QC_JEV_KEY_FILE`, and/or `QC_CHAT_URL` + `QC_CHAT_MODEL`
///   (+ `QC_CHAT_KEY_FILE`, `QC_CHAT_EXTRA` as a JSON object), in router order.
final class QuickCaptureReplayLiveTests: XCTestCase {
    private struct Capture: Decodable {
        let id: String
        let expected: String
        let text: String
    }

    private struct ProjectEntry: Decodable {
        let key: String
        let name: String
        let terms: [String]
        let userLine: String?
    }

    /// Prints a classifier's error (`Log` is silent on Linux), and retries a
    /// 429 up to five times with backoff: the replay measures the routing,
    /// not the provider's load at that minute. The app itself falls back on
    /// the first failure.
    private struct Printing: QuickCaptureClassifying {
        let inner: any QuickCaptureClassifying
        var kind: QuickCaptureRoute.Classifier { inner.kind }
        func classify(capture: String, options: [QuickCaptureOption]) async throws -> [String: Double] {
            var attempt = 0
            while true {
                do {
                    return try await inner.classify(capture: capture, options: options)
                } catch Jev.Failure.http(status: 429, _) where attempt < 5 {
                    attempt += 1
                    print("QC retry \(inner.kind.rawValue): 429, attempt \(attempt)")
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
                } catch {
                    print("QC error \(inner.kind.rawValue): \(error)")
                    throw error
                }
            }
        }
    }

    func testReplay() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LV_QUICK_CAPTURE_REPLAY"] == "1" else {
            throw XCTSkip("spends tokens: run through scripts/linux/quick-capture-replay.sh")
        }
        let captures = try String(contentsOfFile: try XCTUnwrap(environment["QC_CAPTURES"]), encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(Capture.self, from: Data($0.utf8)) }
        let entries = try JSONDecoder().decode(
            [ProjectEntry].self,
            from: Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(environment["QC_PROJECTS"])))
        )
        let projects = entries.map { entry in
            QuickCaptureProject(
                key: entry.key,
                name: entry.name,
                summary: entry.key.hasPrefix("/")
                    ? QuickCaptureProjects.readme(atRoot: entry.key).flatMap(QuickCaptureProjects.firstParagraph(ofReadme:))
                    : nil,
                terms: entry.terms,
                userLine: entry.userLine
            )
        }

        func key(_ variable: String) -> String {
            guard let path = environment[variable], !path.isEmpty,
                  let text = try? String(contentsOfFile: path, encoding: .utf8)
            else { return "" }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var classifiers: [any QuickCaptureClassifying] = []
        if let host = environment["QC_JEV_HOST"].flatMap(Jev.Host.init(rawValue:)) {
            let key = key("QC_JEV_KEY_FILE")
            XCTAssertFalse(key.isEmpty, "no Jev key")
            classifiers.append(JevClassifier(host: host, apiKey: key))
        }
        if let url = environment["QC_CHAT_URL"].flatMap(URL.init(string:)), let model = environment["QC_CHAT_MODEL"] {
            let extra = environment["QC_CHAT_EXTRA"]
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            classifiers.append(QuickCaptureChatClassifier(
                endpoint: url,
                apiKey: key("QC_CHAT_KEY_FILE"),
                model: model,
                extraBody: extra.mapValues { $0 as! any Sendable }
            ))
        }
        XCTAssertFalse(classifiers.isEmpty, "no classifier configured")

        print("QC projects:")
        for option in QuickCaptureRouting.options(for: projects) {
            print("QC   \(option.id): \(option.description)")
        }
        let router = QuickCaptureRouter(classifiers: classifiers.map { Printing(inner: $0) })
        let names = Dictionary(projects.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
        let projectNames = Set(projects.map(\.name))
        var right = 0, projectExpected = 0, projectRight = 0, catchAll = 0, wrongProject = 0, inboxRight = 0, failed = 0
        for capture in captures {
            let expected = projectNames.contains(capture.expected) ? capture.expected : "inbox"
            let route = await router.route(capture: capture.text, projects: projects)
            let got: String
            switch route.destination {
            case .project(let key): got = names[key] ?? key
            case .catchAll: got = "inbox"
            }
            if got == expected { right += 1 }
            if expected == "inbox" {
                if got == "inbox" { inboxRight += 1 }
            } else {
                projectExpected += 1
                if got == expected { projectRight += 1 }
            }
            if got == "inbox" { catchAll += 1 } else if got != expected { wrongProject += 1 }
            if route.reason == .classifierFailed { failed += 1 }
            let mark = got == expected ? "ok " : (got == "inbox" ? "inb" : "BAD")
            let probability = route.topProbability.map { String(format: "%.2f", $0) } ?? "-"
            print("QC \(mark) \(capture.id) expected=\(expected) got=\(got) by=\(route.classifier.rawValue) \(route.reason.rawValue) p=\(probability)")
        }
        print("QC SCORE captures=\(captures.count) right=\(right) project-expected=\(projectExpected) right-project=\(projectRight) catch-all=\(catchAll) wrong-project=\(wrongProject) inbox-expected=\(captures.count - projectExpected) inbox-right=\(inboxRight) failed=\(failed)")
    }
}
