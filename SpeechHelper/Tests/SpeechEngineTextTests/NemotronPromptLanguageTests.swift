import XCTest

@testable import SpeechEngineText

final class NemotronPromptLanguageTests: XCTestCase {
    /// Keys and indices from Nemotron Unified's `prompt_dictionary`
    /// (T0mSIlver/nemotron-labs-unified-asr-0.6b-8bit@b7108f13), the ones these cases touch.
    private let unified: [String: Int] = [
        "en-US": 0, "en": 0, "en-GB": 1, "es-ES": 2, "es": 3, "fr-FR": 8, "fr": 8, "fr-CA": 100,
        "de-DE": 9, "de": 9, "ja-JP": 10, "ja-JA": 10, "pt-BR": 12, "pt-PT": 13, "pt": 13,
        "th-TH": 32, "mt-MT": 102, "mt": 102, "auto": 127,
    ]

    func testEveryOneOfUnifiedsLanguagesHasItsOwnKey() {
        for (code, index) in ["en": 0, "es": 3, "fr": 8, "de": 9, "pt": 13, "mt": 102] {
            let key = NemotronPromptLanguage.key(for: code, in: unified)
            XCTAssertEqual(key, code)
            XCTAssertEqual(key.flatMap { unified[$0] }, index, code)
        }
    }

    /// NeMo's rule: an exact key wins; a bare code takes the one key it prefixes.
    func testALocaleKeyOrAUniquePrefix() {
        XCTAssertEqual(NemotronPromptLanguage.key(for: "pt-BR", in: unified), "pt-BR")
        XCTAssertEqual(NemotronPromptLanguage.key(for: "th", in: unified), "th-TH")
    }

    /// Anything else leaves the model on its own detection.
    func testNoLanguageAnUnknownOneOrAnAmbiguousOneIsAuto() {
        XCTAssertNil(NemotronPromptLanguage.key(for: nil, in: unified))
        XCTAssertNil(NemotronPromptLanguage.key(for: "", in: unified))
        XCTAssertNil(NemotronPromptLanguage.key(for: "xx", in: unified))
        XCTAssertNil(NemotronPromptLanguage.key(for: "ja", in: unified))
        XCTAssertNil(NemotronPromptLanguage.key(for: "fr", in: [:]))
    }
}
