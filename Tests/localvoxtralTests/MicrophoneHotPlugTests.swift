import Foundation
import XCTest
@testable import localvoxtral

/// The microphone list must follow CoreAudio while the app is idle: a mic
/// plugged in after launch used to stay out of the menu until relaunch,
/// because device-change events were only acted on during dictation.
@MainActor
final class MicrophoneHotPlugTests: XCTestCase {
    private let builtIn = MicrophoneInputDevice(
        id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", channelCount: 1)
    private let usb = MicrophoneInputDevice(
        id: "AppleUSBAudioEngine:Rode:NT-USB:1", name: "NT-USB", channelCount: 2)

    func testMicrophonePluggedInWhileIdleIsListed() {
        let (viewModel, _) = makeViewModel()
        viewModel.microphone.debugConfigureDeviceEnumeration(
            devices: [builtIn], defaultInputDeviceID: builtIn.id)
        viewModel.refreshMicrophoneInputs()
        XCTAssertEqual(viewModel.availableInputDevices, [builtIn])

        viewModel.microphone.debugConfigureDeviceEnumeration(
            devices: [builtIn, usb], defaultInputDeviceID: builtIn.id)
        viewModel.handleMicrophoneInputDevicesChanged()

        XCTAssertEqual(viewModel.availableInputDevices, [builtIn, usb])
        XCTAssertEqual(
            viewModel.selectedInputDeviceID, builtIn.id,
            "plugging a mic in lists it; it must not steal the selection"
        )
    }

    func testMicrophoneUnpluggedWhileIdleIsReselectedWhenPluggedBack() {
        let (viewModel, settings) = makeViewModel()
        viewModel.microphone.debugConfigureDeviceEnumeration(
            devices: [builtIn, usb], defaultInputDeviceID: builtIn.id)
        viewModel.refreshMicrophoneInputs()
        viewModel.selectMicrophoneInput(id: usb.id)

        viewModel.microphone.debugConfigureDeviceEnumeration(
            devices: [builtIn], defaultInputDeviceID: builtIn.id)
        viewModel.handleMicrophoneInputDevicesChanged()

        XCTAssertEqual(viewModel.availableInputDevices, [builtIn])
        XCTAssertEqual(viewModel.selectedInputDeviceID, builtIn.id)
        XCTAssertEqual(
            settings.selectedInputDeviceUID, usb.id,
            "a mic that is only unplugged stays the saved choice"
        )

        viewModel.microphone.debugConfigureDeviceEnumeration(
            devices: [builtIn, usb], defaultInputDeviceID: builtIn.id)
        viewModel.handleMicrophoneInputDevicesChanged()

        XCTAssertEqual(viewModel.selectedInputDeviceID, usb.id)
    }

    func testPickingTheFallbackWhileSavedMicIsUnpluggedSavesIt() {
        let (viewModel, settings) = makeViewModel()
        viewModel.microphone.debugConfigureDeviceEnumeration(
            devices: [builtIn, usb], defaultInputDeviceID: builtIn.id)
        viewModel.refreshMicrophoneInputs()
        viewModel.selectMicrophoneInput(id: usb.id)
        viewModel.microphone.debugConfigureDeviceEnumeration(
            devices: [builtIn], defaultInputDeviceID: builtIn.id)
        viewModel.handleMicrophoneInputDevicesChanged()

        viewModel.selectMicrophoneInput(id: builtIn.id)
        viewModel.microphone.debugConfigureDeviceEnumeration(
            devices: [builtIn, usb], defaultInputDeviceID: builtIn.id)
        viewModel.handleMicrophoneInputDevicesChanged()

        XCTAssertEqual(settings.selectedInputDeviceUID, builtIn.id)
        XCTAssertEqual(viewModel.selectedInputDeviceID, builtIn.id)
    }

    func testFirstRefreshSavesTheResolvedDefault() {
        let (viewModel, settings) = makeViewModel()
        viewModel.microphone.debugConfigureDeviceEnumeration(
            devices: [builtIn, usb], defaultInputDeviceID: usb.id)

        viewModel.refreshMicrophoneInputs()

        XCTAssertEqual(viewModel.selectedInputDeviceID, usb.id)
        XCTAssertEqual(settings.selectedInputDeviceUID, usb.id)
    }

    private func makeViewModel() -> (DictationViewModel, SettingsStore) {
        let suiteName = "localvoxtral.MicrophoneHotPlugTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false
        )
        retainForTestProcessLifetime(viewModel)
        return (viewModel, settings)
    }
}
