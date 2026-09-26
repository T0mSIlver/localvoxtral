import Foundation
import Synchronization
import XCTest

@testable import localvoxtralCore

final class QuickCaptureRouterTests: XCTestCase {
    private final class Fake: QuickCaptureClassifying, @unchecked Sendable {
        let kind: QuickCaptureRoute.Classifier
        let answer: Result<[String: Double], Jev.Failure>
        let calls = Mutex(0)
        init(kind: QuickCaptureRoute.Classifier, answer: Result<[String: Double], Jev.Failure>) {
            self.kind = kind
            self.answer = answer
        }
        func classify(capture: String, options: [QuickCaptureOption]) async throws -> [String: Double] {
            calls.withLock { $0 += 1 }
            return try answer.get()
        }
    }

    private let projects = [
        QuickCaptureProject(key: "/w/localvoxtral", name: "localvoxtral", summary: "Dictation app.", terms: [], userLine: nil),
        QuickCaptureProject(key: "remote:website", name: "website", summary: nil, terms: ["Astro"], userLine: nil),
    ]

    // MARK: Options

    func testEachProjectGetsAnIdFromItsNameAndTheCatchAllComesLast() {
        let options = QuickCaptureRouting.options(for: projects + [
            QuickCaptureProject(key: "remote:localvoxtral", name: "localvoxtral", summary: nil, terms: [], userLine: nil),
            QuickCaptureProject(key: "/w/x", name: "Inbox", summary: nil, terms: [], userLine: nil),
            QuickCaptureProject(key: "/w/y", name: "Mon Projet_2", summary: nil, terms: [], userLine: nil),
        ])
        XCTAssertEqual(options.map(\.id), ["localvoxtral", "website", "localvoxtral-2", "inbox-2", "mon-projet-2", "inbox"])
        XCTAssertEqual(options.last?.projectKey, nil)
        XCTAssertEqual(options[2].projectKey, "remote:localvoxtral")
    }

    // MARK: Decision

    func testOnlyAConfidentClearWinnerIsRoutedToAProject() {
        let options = QuickCaptureRouting.options(for: projects)
        let cases: [(String, [String: Double], QuickCaptureRoute.Destination, QuickCaptureRoute.Reason)] = [
            ("clear winner", ["localvoxtral": 0.8, "website": 0.1, "inbox": 0.1], .project("/w/localvoxtral"), .confident),
            ("at both bars", ["website": 0.5, "localvoxtral": 0.35], .project("remote:website"), .confident),
            ("low top", ["localvoxtral": 0.45, "website": 0.2, "inbox": 0.35], .catchAll, .lowConfidence),
            ("near tie", ["localvoxtral": 0.52, "website": 0.40], .catchAll, .nearTie),
            ("catch-all chosen", ["inbox": 0.9, "localvoxtral": 0.1], .catchAll, .classifierChoseCatchAll),
            ("unknown ids ignored", ["other": 0.99, "website": 0.01], .catchAll, .lowConfidence),
        ]
        for (name, probabilities, destination, reason) in cases {
            let route = QuickCaptureRouting.decide(probabilities: probabilities, options: options, classifier: .jev)
            XCTAssertEqual(route.destination, destination, name)
            XCTAssertEqual(route.reason, reason, name)
            XCTAssertEqual(route.classifier, .jev, name)
        }
    }

    func testAChatModelNeedsNinetyPercentBecauseItsConfidenceIsNotCalibrated() {
        let options = QuickCaptureRouting.options(for: projects)
        let unsure = QuickCaptureRouting.decide(probabilities: ["website": 0.85], options: options, classifier: .chatModel)
        let sure = QuickCaptureRouting.decide(probabilities: ["website": 0.9], options: options, classifier: .chatModel)
        XCTAssertEqual(unsure.reason, .lowConfidence)
        XCTAssertEqual(sure.destination, .project("remote:website"))
    }

    // MARK: Router

    func testAFailedClassifierFallsBackToTheNext() async {
        let jev = Fake(kind: .jev, answer: .failure(.http(status: 401, message: "bad key")))
        let chat = Fake(kind: .chatModel, answer: .success(["website": 0.9]))
        let route = await QuickCaptureRouter(classifiers: [jev, chat]).route(capture: "Fix the hero image", projects: projects)
        XCTAssertEqual(route, QuickCaptureRoute(destination: .project("remote:website"), classifier: .chatModel, reason: .confident, topProbability: 0.9))
        XCTAssertEqual(jev.calls.withLock { $0 }, 1)
    }

    func testEveryClassifierFailingKeepsTheCaptureInTheInbox() async {
        let jev = Fake(kind: .jev, answer: .failure(.malformedResponse))
        let route = await QuickCaptureRouter(classifiers: [jev]).route(capture: "An idea", projects: projects)
        XCTAssertEqual(route.destination, .catchAll)
        XCTAssertEqual(route.reason, .classifierFailed)
    }

    func testNothingIsAskedWithoutProjectsOrWords() async {
        let jev = Fake(kind: .jev, answer: .success(["localvoxtral": 1]))
        let router = QuickCaptureRouter(classifiers: [jev])
        let none = await router.route(capture: "An idea", projects: [])
        let empty = await router.route(capture: " \n", projects: projects)
        XCTAssertEqual(none.reason, .noProjects)
        XCTAssertEqual(empty.reason, .emptyCapture)
        XCTAssertEqual(jev.calls.withLock { $0 }, 0)
    }
}
