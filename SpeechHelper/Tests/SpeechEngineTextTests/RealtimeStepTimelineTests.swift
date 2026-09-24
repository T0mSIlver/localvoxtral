import XCTest

@testable import SpeechEngineText

final class RealtimeStepTimelineTests: XCTestCase {
    func testTextAppearsWhenItsStepFinishesAfterItsAudioArrived() {
        var timeline = RealtimeStepTimeline(sampleRate: 1_000)
        timeline.record(audioSamples: 100, latencySeconds: 0.05, transcript: "")
        timeline.record(audioSamples: 200, latencySeconds: 0.05, transcript: "hello there")
        timeline.record(audioSamples: 300, latencySeconds: 0.05, transcript: "hello there friend")

        XCTAssertEqual(timeline.firstTextSeconds ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(timeline.wordAppearanceSeconds.count, 3)
        XCTAssertEqual(timeline.wordAppearanceSeconds[1], 0.25, accuracy: 1e-9)
        XCTAssertEqual(timeline.wordAppearanceSeconds[2], 0.35, accuracy: 1e-9)
        XCTAssertEqual(timeline.maxLagSeconds, 0.05, accuracy: 1e-9)
    }

    func testAStepSlowerThanTheCadenceDelaysTheStepsAfterIt() {
        var timeline = RealtimeStepTimeline(sampleRate: 1_000)
        timeline.record(audioSamples: 100, latencySeconds: 0.25, transcript: "")
        // Arrived at 0.2 s but waits for the first step, which ends at 0.35 s.
        timeline.record(audioSamples: 200, latencySeconds: 0.05, transcript: "late")

        XCTAssertEqual(timeline.firstTextSeconds ?? -1, 0.40, accuracy: 1e-9)
        XCTAssertEqual(timeline.maxLagSeconds, 0.25, accuracy: 1e-9)
    }

    func testNoTextLeavesFirstTextUnset() {
        var timeline = RealtimeStepTimeline(sampleRate: 1_000)
        timeline.record(audioSamples: 100, latencySeconds: 0.01, transcript: "  ")

        XCTAssertNil(timeline.firstTextSeconds)
    }
}
