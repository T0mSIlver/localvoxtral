import Foundation
import XCTest
import localvoxtralTestSupport
@testable import localvoxtral

/// A slow preferences daemon can answer a read with the value from before this
/// copy's last write. On a hosted run that cost half of 401 refusals (LVX-102):
/// the list merge took each missing newest item for another copy's removal.
@MainActor
final class ListSettingLaggingReadTests: XCTestCase {
    /// Every read of a key returns the value it held before the last write.
    private final class LaggingDefaults: UserDefaults, @unchecked Sendable {
        private var beforeLastWrite: [String: Any] = [:]

        override func set(_ value: Any?, forKey key: String) {
            beforeLastWrite[key] = super.object(forKey: key) ?? NSNull()
            super.set(value, forKey: key)
        }

        override func stringArray(forKey key: String) -> [String]? {
            guard let previous = beforeLastWrite[key] else { return super.stringArray(forKey: key) }
            return previous as? [String]
        }

        override func string(forKey key: String) -> String? {
            guard let previous = beforeLastWrite[key] else { return super.string(forKey: key) }
            return previous as? String
        }
    }

    private func makeLaggingSettings() throws -> SettingsStore {
        let suite = makeTestDefaultsSuite()
        let defaults = try XCTUnwrap(LaggingDefaults(suiteName: suite.suiteName))
        return SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
    }

    func testRefusalsSurviveReadsThatLagThisCopysOwnWrites() async throws {
        let settings = try makeLaggingSettings()
        for index in 0...SpeakerTermSuggestions.maxDismissed {
            settings.dismissTermSuggestion("Refused\(index)x")
        }
        XCTAssertEqual(settings.polishDismissedTermSuggestions.count, SpeakerTermSuggestions.maxDismissed)
        XCTAssertEqual(settings.polishDismissedTermSuggestions.first, "Refused1x")
        XCTAssertEqual(settings.polishDismissedTermSuggestions.last, "Refused\(SpeakerTermSuggestions.maxDismissed)x")
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
