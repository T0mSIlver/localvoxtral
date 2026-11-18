import Foundation
import XCTest
import localvoxtralTestSupport
@testable import localvoxtral

/// A slow preferences daemon can answer a read with the value from before this
/// copy's last write. On a hosted run that cost half of 401 refusals (LVX-102):
/// the list merge took each missing newest item for another copy's removal.
@MainActor
final class ListSettingLaggingReadTests: XCTestCase {
    /// Every read of a key returns the value it held `depth` writes ago: the
    /// hosted runs kept 205 and then 77 of 401 refusals, so a slow daemon can
    /// answer from far behind.
    private final class LaggingDefaults: UserDefaults, @unchecked Sendable {
        var depth = 1
        private var history: [String: [Any]] = [:]

        override func set(_ value: Any?, forKey key: String) {
            history[key, default: []].append(super.object(forKey: key) ?? NSNull())
            super.set(value, forKey: key)
        }

        private func lagging(_ key: String) -> Any?? {
            guard let past = history[key], !past.isEmpty else { return .none }
            return .some(past[max(0, past.count - depth)])
        }

        override func stringArray(forKey key: String) -> [String]? {
            guard let value = lagging(key) else { return super.stringArray(forKey: key) }
            return value as? [String]
        }

        override func string(forKey key: String) -> String? {
            guard let value = lagging(key) else { return super.string(forKey: key) }
            return value as? String
        }
    }

    private func makeLaggingSettings(depth: Int = 1) throws -> SettingsStore {
        let suite = makeTestDefaultsSuite()
        let defaults = try XCTUnwrap(LaggingDefaults(suiteName: suite.suiteName))
        defaults.depth = depth
        return SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
    }

    func testRefusalsSurviveReadsThatLagThisCopysOwnWrites() async throws {
        for depth in [1, 3, 50] {
            let settings = try makeLaggingSettings(depth: depth)
            for index in 0...SpeakerTermSuggestions.maxDismissed {
                settings.dismissTermSuggestion("Refused\(index)x")
            }
            XCTAssertEqual(
                settings.polishDismissedTermSuggestions.count, SpeakerTermSuggestions.maxDismissed, "lag \(depth)")
            XCTAssertEqual(settings.polishDismissedTermSuggestions.first, "Refused1x", "lag \(depth)")
            XCTAssertEqual(
                settings.polishDismissedTermSuggestions.last, "Refused\(SpeakerTermSuggestions.maxDismissed)x",
                "lag \(depth)")
        }
    }

    func testTermsSurviveReadsThatLagThisCopysOwnWrites() async throws {
        let settings = try makeLaggingSettings()
        let terms = (0..<20).map { "Term\($0)x" }
        for term in terms { settings.polishSpeakerTerms.append(term) }
        XCTAssertEqual(settings.polishSpeakerTerms, terms)
    }

    /// Another copy that restores an earlier list removed something: the
    /// list matches one this copy saved before, but this copy did not save
    /// it last, so the removal stands (Codex review).
    func testAnotherCopysRemovalStandsWhenItRestoresAnEarlierList() async {
        let defaults = makeTestDefaults()
        func makeStore() -> SettingsStore {
            SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        }
        let first = makeStore()
        first.polishSpeakerTerms.append("Qwen")
        first.polishSpeakerTerms.append("Claude Code")
        let second = makeStore()
        second.polishSpeakerTerms.removeAll { $0 == "Claude Code" }

        first.polishSpeakerTerms.append("Ghostty")
        XCTAssertEqual(first.polishSpeakerTerms, ["Qwen", "Ghostty"])
        XCTAssertEqual(makeStore().polishSpeakerTerms, ["Qwen", "Ghostty"])
    }
}
