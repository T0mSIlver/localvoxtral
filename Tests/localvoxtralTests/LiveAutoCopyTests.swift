import Foundation
import XCTest
@testable import localvoxtral

// Live Auto-Paste with "Copy on stop" on puts the dictation so far on the
// clipboard after each final. The popover's "Copy latest segment" read the
// same text; it is gone (#793), and this path is its only reader left.
#if DEBUG
@MainActor
final class LiveAutoCopyTests: XCTestCase {
    private func makeViewModel(autoCopy: Bool) -> (DictationViewModel, PasteboardWrites) {
        let suiteName = "localvoxtral.LiveAutoCopyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        settings.dictationOutputMode = .liveAutoPaste
        settings.autoCopyEnabled = autoCopy

        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)
        viewModel.isDictating = true
        viewModel.textInsertion.debugConfigureInsertionHooks(
            unicodePoster: { _ in true },
            modifierStateReader: { false },
            accessibilityInserter: { _, _ in false }
        )

        return (viewModel, viewModel.recordPasteboardWrites())
    }

    func testEachFinalCopiesTheDictationSoFar() {
        let (viewModel, written) = makeViewModel(autoCopy: true)

        viewModel.session.handle(event: .finalTranscript("first part."))
        viewModel.session.handle(event: .finalTranscript("second part."))

        XCTAssertEqual(written.values, ["first part.", "first part. second part."])
    }

    func testWithAutoCopyOffNothingIsCopied() {
        let (viewModel, written) = makeViewModel(autoCopy: false)

        viewModel.session.handle(event: .finalTranscript("first part."))

        XCTAssertEqual(written.values, [])
    }
}
#endif
