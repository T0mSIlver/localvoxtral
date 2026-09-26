import Foundation
import XCTest
@testable import localvoxtral

// Live Auto-Paste with "Copy on stop" on puts each finalized segment on the
// clipboard as it is typed. The popover's "Copy latest segment" read the same
// text; it is gone (#793), and this path is its only reader left.
#if DEBUG
@MainActor
final class LiveAutoCopyTests: XCTestCase {
    private final class Written {
        var values: [String] = []
    }

    private func makeViewModel(autoCopy: Bool) -> (DictationViewModel, Written) {
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

        let written = Written()
        viewModel.dependencies.pasteboardWriter = { written.values.append($0) }
        return (viewModel, written)
    }

    func testEachFinalizedSegmentIsCopiedSilently() {
        let (viewModel, written) = makeViewModel(autoCopy: true)
        let statusBefore = viewModel.statusText

        viewModel.session.handle(event: .finalTranscript("first part."))
        viewModel.session.handle(event: .finalTranscript("second part."))

        XCTAssertEqual(written.values, ["first part.", "second part."])
        XCTAssertEqual(viewModel.statusText, statusBefore)
    }

    func testWithAutoCopyOffNothingIsCopied() {
        let (viewModel, written) = makeViewModel(autoCopy: false)

        viewModel.session.handle(event: .finalTranscript("first part."))

        XCTAssertEqual(written.values, [])
    }
}
#endif
