import AppKit
import SwiftUI
import XCTest

@testable import localvoxtral

/// Pictures of the app's views, one PNG per view and state, for a reviewer
/// who cannot open the app: `build-test` uploads them as the `view-snapshots`
/// artifact. Record-only: nothing is compared against a stored image.
///
/// Every model is built here from fakes over throwaway defaults, so no image
/// holds anything from the machine that ran it: no transcripts, no paths, no
/// device names. The artifacts are public.
@MainActor
final class ViewSnapshotTests: XCTestCase {
    /// `SettingsScene`'s default size.
    private static let settingsSize = CGSize(width: 780, height: 560)

    // MARK: - Settings

    func testSettingsPanes() throws {
        let panes: [SettingsTab] =
            SettingsTab.historySidebarItems
            + SettingsTab.primarySidebarItems
            + SettingsTab.integrationsSidebarItems
            + [SettingsTab.terminal(TerminalAppCatalog.builtIn[0])]
        for pane in panes {
            let (settings, viewModel) = makeViewModel()
            let navigator = SettingsNavigator()
            navigator.selectedTab = pane
            let view = SettingsView(
                settings: settings,
                viewModel: viewModel,
                backendManager: BackendManager(),
                navigator: navigator,
                loginItem: LoginItemController(registrar: FakeLoginItemRegistrar(state: .disabled))
            )
            .environment(\.shortcutRecorderStandIn, true)
            try record(
                view, name: "settings-\(pane.rawValue)",
                width: Self.settingsSize.width, height: Self.settingsSize.height, growToFit: true)
        }
    }

    // MARK: - Status popover

    /// The menu bar item's content. The app shows it as an `NSMenu`
    /// (`.menuBarExtraStyle(.menu)`); hosted in a window it draws as the
    /// controls it is made of, which still shows each row and whether it is
    /// enabled.
    func testStatusPopoverStates() throws {
        let states: [(name: String, apply: (DictationViewModel) -> Void)] = [
            ("idle", { _ in }),
            ("connecting", {
                $0.isConnectingRealtimeSession = true
                $0.statusText = DictationViewModel.StatusStrings.connectingRealtimeBackend
            }),
            ("dictating", {
                $0.isDictating = true
                $0.statusText = "Listening"
            }),
            ("finalizing", {
                $0.isFinalizingStop = true
                $0.statusText = DictationViewModel.StatusStrings.polishing
            }),
            ("connection-refused", {
                $0.statusText = "Connection refused."
                $0.lastError = "Connection refused."
            }),
        ]
        for state in states {
            let (_, viewModel) = makeViewModel()
            state.apply(viewModel)
            let view = StatusPopoverView(viewModel: viewModel, navigator: SettingsNavigator())
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor))
            try record(view, name: "popover-\(state.name)", width: 304, height: 420, growToFit: false)
        }
    }

    // MARK: - Overlay panel

    func testOverlayPanelStates() throws {
        let metrics = OverlayLayoutMetrics(bodyFontSize: OverlayLayoutMetrics.defaultBodyFontSize)
        let sample = "Rename the retry helper and run the unit tests again."
        let states: [(name: String, view: DictationOverlayView)] = [
            ("ready", DictationOverlayView(
                phase: .idle, text: "", errorMessage: nil, secureInputActive: false,
                metrics: metrics)),
            ("listening", DictationOverlayView(
                phase: .buffering, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics)),
            ("listening-joined", DictationOverlayView(
                phase: .buffering, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics, claudeJoin: .joined(label: "localvoxtral"))),
            ("listening-unjoined", DictationOverlayView(
                phase: .buffering, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics, claudeJoin: .unjoined)),
            ("secure-input", DictationOverlayView(
                phase: .buffering, text: sample, errorMessage: nil, secureInputActive: true,
                metrics: metrics)),
            ("finalizing", DictationOverlayView(
                phase: .finalizing, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics)),
            ("polished", DictationOverlayView(
                phase: .finalizing, text: sample, errorMessage: nil, secureInputActive: false,
                metrics: metrics, polished: true)),
            ("commit-failed", DictationOverlayView(
                phase: .commitFailed, text: sample,
                errorMessage: "Couldn't insert. Copied for manual paste.",
                secureInputActive: false, metrics: metrics)),
        ]
        for state in states {
            let height = metrics.contentHeight(text: state.view.text, errorMessage: state.view.errorMessage)
            // A flat backdrop stands in for the desktop the panel floats over.
            let inset: CGFloat = 16
            let view = state.view
                .frame(width: metrics.panelWidth, height: height)
                .padding(inset)
                .background(Color(white: 0.55))
            try record(
                view, name: "overlay-\(state.name)",
                width: metrics.panelWidth + 2 * inset, height: height + 2 * inset, growToFit: false)
        }
    }

    // MARK: - Support

    private func makeViewModel() -> (SettingsStore, DictationViewModel) {
        let settings = makeSettings()
        let microphone = FakeMicrophoneCaptureService()
        microphone.configureDevices(
            [MicrophoneInputDevice(id: "snapshot-mic", name: "Built-in Microphone", channelCount: 1)],
            defaultInputDeviceID: "snapshot-mic")
        let viewModel = DictationViewModel(
            settings: settings,
            backendManager: OnboardingTestBackendManager(),
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false,
            dependencies: .init(microphone: { microphone }, clock: ManualSessionClock().clock)
        )
        viewModel.appConfigStore = MockAppConfigStore()
        retainForTestProcessLifetime(viewModel)
        return (settings, viewModel)
    }

    private func record<V: View>(
        _ view: V, name: String, width: CGFloat, height: CGFloat, growToFit: Bool
    ) throws {
        let url = try ViewSnapshot.record(
            view, name: name, width: width, height: height, growToFit: growToFit)
        // The hosting view sizes its window to the content, so the image is
        // the view's own size, not necessarily the one asked for.
        let image = try XCTUnwrap(NSImage(contentsOf: url), "\(name).png does not read back")
        XCTAssertGreaterThan(image.size.width, 0, name)
        XCTAssertGreaterThan(image.size.height, 0, name)
    }
}
