import XCTest
import localvoxtralTestSupport

/// The eval TTS voice comes from `say -v '?'` text, whose format changed
/// with macOS 27 (#960).
final class EvalVoicePickingTests: XCTestCase {
    /// macOS 15: plain names.
    private let macOS15Voices = """
        Alex                en_US    # Most people recognize me by my voice.
        Amélie              fr_CA    # Bonjour! Je m'appelle Amélie.
        Bad News            en_US    # The light you see at the end of the tunnel...
        Samantha            en_US    # Hello! My name is Samantha.
        Thomas              fr_FR    # Bonjour! Je m'appelle Thomas.
        """

    /// macOS 27, as the build host listed it on 2026-09-27: most names carry
    /// a locale suffix, and a novelty voice sorts first.
    private let macOS27Voices = """
        Albert                           en_US    # Hello! My name is Albert.
        Amélie                           fr_CA    # Bonjour! Je m'appelle Amélie.
        Daniel                           en_GB    # Hello! My name is Daniel.
        Eddy (English (UK))              en_GB    # Hello! My name is Eddy.
        Jacques                          fr_FR    # Bonjour! Je m'appelle Jacques.
        Karen                            en_AU    # Hello! My name is Karen.
        Moira                            en_IE    # Hello! My name is Moira.
        Samantha (English (US))          en_US    # Hello! My name is Samantha.
        Thomas (French (France))         fr_FR    # Bonjour! Je m'appelle Thomas.
        """

    private func pick(_ output: String, _ language: String) -> String? {
        let preferred = language == "fr"
            ? EvalSpeechStage.frenchVoicePreference
            : EvalSpeechStage.englishVoicePreference
        return EvalSpeechStage.pickVoice(
            fromSayVoicesOutput: output, languagePrefix: language, preferred: preferred
        )
    }

    /// The eval on the Actions runner listed 187 voices, yet picked none of
    /// Samantha, Alex or Daniel, while the English names it did parse were
    /// all short (run 36508524473, #960): a long name need not leave two
    /// spaces before its locale, and the gap may be a tab or a no-break space.
    func testParsesLongNamesWithANarrowGapBeforeTheLocale() {
        let listing = [
            "Albert              en_US    # Hello! My name is Albert.",
            "Samantha (English (US)) en_US    # Hello! My name is Samantha.",
            "Daniel (English (UK))\ten_GB    # Hello! My name is Daniel.",
            "Thomas (French (France))\u{00A0}fr_FR    # Bonjour! Je m'appelle Thomas.",
        ].joined(separator: "\n")
        XCTAssertEqual(pick(listing, "en"), "Samantha (English (US))")
        XCTAssertEqual(pick(listing, "fr"), "Thomas (French (France))")
        XCTAssertEqual(
            EvalSpeechStage.pickVoice(
                fromSayVoicesOutput: listing, languagePrefix: "en", preferred: ["Daniel"]
            ),
            "Daniel (English (UK))"
        )
    }

    func testPicksPreferredVoicesFromMacOS15Listing() {
        XCTAssertEqual(pick(macOS15Voices, "en"), "Samantha")
        XCTAssertEqual(pick(macOS15Voices, "fr"), "Thomas")
    }

    /// Returns the name as listed, since `say -v` needs it whole.
    func testPicksPreferredVoicesFromMacOS27Listing() {
        XCTAssertEqual(pick(macOS27Voices, "en"), "Samantha (English (US))")
        XCTAssertEqual(pick(macOS27Voices, "fr"), "Thomas (French (France))")
    }

    /// What the Mac's Actions runner lists on macOS 27 (run 36363115511):
    /// no Samantha, Alex or Thomas, so the list's later entries apply.
    private let macOS27RunnerVoices = """
        Albert                           en_US    # Hello! My name is Albert.
        Amélie                           fr_CA    # Bonjour! Je m'appelle Amélie.
        Bad News                         en_US    # ...
        Bahh                             en_US    # ...
        Daniel                           en_GB    # Hello! My name is Daniel.
        Flo (English (UK))               en_GB    # Hello! My name is Flo.
        Flo (English (US))               en_US    # Hello! My name is Flo.
        Fred                             en_US    # ...
        Jacques                          fr_FR    # Bonjour! Je m'appelle Jacques.
        Karen                            en_AU    # Hello! My name is Karen.
        Moira                            en_IE    # Hello! My name is Moira.
        Zarvox                           en_US    # ...
        """

    func testRunnerListingFallsBackAlongThePreferenceList() {
        XCTAssertEqual(pick(macOS27RunnerVoices, "en"), "Daniel")
        XCTAssertEqual(pick(macOS27RunnerVoices, "fr"), "Jacques")
        XCTAssertEqual(
            EvalSpeechStage.fallbackNote(
                chosen: "Daniel", preferred: EvalSpeechStage.englishVoicePreference
            ),
            "Samantha, Alex not listed by `say -v ?`, using Daniel"
        )
        XCTAssertNil(
            EvalSpeechStage.fallbackNote(
                chosen: "Samantha (English (US))",
                preferred: EvalSpeechStage.englishVoicePreference
            )
        )
    }

    /// Amélie (fr_CA) is the last French choice.
    func testFrenchFallsBackToAmelie() {
        let output = """
            Amélie                           fr_CA    # Bonjour! Je m'appelle Amélie.
            Audrey (French (France))         fr_FR    # Bonjour! Je m'appelle Audrey.
            """
        XCTAssertEqual(pick(output, "fr"), "Amélie")
    }

    /// No fallback to a voice off the list: Albert is what the old
    /// fallback chose on macOS 27, and speechd transcribed nothing of it.
    func testListingWithoutPreferredVoicePicksNone() {
        let output = """
            Albert                           en_US    # Hello! My name is Albert.
            Audrey (French (France))         fr_FR    # Bonjour! Je m'appelle Audrey.
            """
        XCTAssertNil(pick(output, "en"))
        XCTAssertNil(pick(output, "fr"))
    }

    /// Eval setup fails naming the wanted voices and what was on offer.
    func testRequireVoiceFailsNamingMissingAndOfferedVoices() {
        let output = """
            Albert                           en_US    # Hello! My name is Albert.
            Eddy (English (UK))              en_GB    # Hello! My name is Eddy.
            Jacques                          fr_FR    # Bonjour! Je m'appelle Jacques.
            """
        XCTAssertThrowsError(
            try EvalSpeechStage.requireVoice(
                fromSayVoicesOutput: output, languagePrefix: "en",
                preferred: EvalSpeechStage.englishVoicePreference
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                "no en TTS voice named Samantha or Alex or Daniel; "
                    + "`say -v ?` offered: Albert, Eddy (English (UK))"
            )
        }
        XCTAssertEqual(
            try EvalSpeechStage.requireVoice(
                fromSayVoicesOutput: macOS27Voices, languagePrefix: "fr",
                preferred: EvalSpeechStage.frenchVoicePreference
            ),
            "Thomas (French (France))"
        )
    }

    func testPreferredNameMatchesOnlyWholeOrBeforeLocaleSuffix() {
        let output = """
            Samanthaa                        en_US    # ...
            Samantha Enhanced                en_US    # ...
            Alex (English (US))              en_US    # ...
            """
        XCTAssertEqual(pick(output, "en"), "Alex (English (US))")
    }

    /// Multi-word names ("Bad News") parse whole, and hyphenated locales
    /// (fr-FR) still match the language prefix.
    func testParsesMultiWordNamesAndHyphenLocales() {
        let output = """
            Bad News            en_US    # ...
            Jacques             fr-FR    # ...
            """
        XCTAssertEqual(
            EvalSpeechStage.pickVoice(
                fromSayVoicesOutput: output, languagePrefix: "en", preferred: ["Bad News"]
            ),
            "Bad News"
        )
        XCTAssertEqual(
            EvalSpeechStage.pickVoice(
                fromSayVoicesOutput: output, languagePrefix: "fr", preferred: ["Jacques"]
            ),
            "Jacques"
        )
    }
}
