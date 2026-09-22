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
        let (audio, _) = makePipeline()
        audio.fakeMicrophone.configureDevices(
            [builtIn], defaultInputDeviceID: builtIn.id)
        audio.refreshMicrophoneInputs()
        XCTAssertEqual(audio.availableInputDevices, [builtIn])

        audio.fakeMicrophone.configureDevices(
            [builtIn, usb], defaultInputDeviceID: builtIn.id)
        audio.handleMicrophoneInputDevicesChanged()

        XCTAssertEqual(audio.availableInputDevices, [builtIn, usb])
        XCTAssertEqual(
            audio.selectedInputDeviceID, builtIn.id,
            "plugging a mic in lists it; it must not steal the selection"
        )
    }

    func testMicrophoneUnpluggedWhileIdleIsReselectedWhenPluggedBack() {
        let (audio, settings) = makePipeline()
        audio.fakeMicrophone.configureDevices(
            [builtIn, usb], defaultInputDeviceID: builtIn.id)
        audio.refreshMicrophoneInputs()
        audio.selectMicrophoneInput(id: usb.id)

        audio.fakeMicrophone.configureDevices(
            [builtIn], defaultInputDeviceID: builtIn.id)
        audio.handleMicrophoneInputDevicesChanged()

        XCTAssertEqual(audio.availableInputDevices, [builtIn])
        XCTAssertEqual(audio.selectedInputDeviceID, builtIn.id)
        XCTAssertEqual(
            settings.selectedInputDeviceUID, usb.id,
            "a mic that is only unplugged stays the saved choice"
        )

        audio.fakeMicrophone.configureDevices(
            [builtIn, usb], defaultInputDeviceID: builtIn.id)
        audio.handleMicrophoneInputDevicesChanged()

        XCTAssertEqual(audio.selectedInputDeviceID, usb.id)
    }

    func testPickingTheFallbackWhileSavedMicIsUnpluggedSavesIt() {
        let (audio, settings) = makePipeline()
        audio.fakeMicrophone.configureDevices(
            [builtIn, usb], defaultInputDeviceID: builtIn.id)
        audio.refreshMicrophoneInputs()
        audio.selectMicrophoneInput(id: usb.id)
        audio.fakeMicrophone.configureDevices(
            [builtIn], defaultInputDeviceID: builtIn.id)
        audio.handleMicrophoneInputDevicesChanged()

        audio.selectMicrophoneInput(id: builtIn.id)
        audio.fakeMicrophone.configureDevices(
            [builtIn, usb], defaultInputDeviceID: builtIn.id)
        audio.handleMicrophoneInputDevicesChanged()

        XCTAssertEqual(settings.selectedInputDeviceUID, builtIn.id)
        XCTAssertEqual(audio.selectedInputDeviceID, builtIn.id)
    }

    func testFirstRefreshSavesTheResolvedDefault() {
        let (audio, settings) = makePipeline()
        audio.fakeMicrophone.configureDevices(
            [builtIn, usb], defaultInputDeviceID: usb.id)

        audio.refreshMicrophoneInputs()

        XCTAssertEqual(audio.selectedInputDeviceID, usb.id)
        XCTAssertEqual(settings.selectedInputDeviceUID, usb.id)
    }

    /// The popover reads the device list, the selection and the channel count
    /// through the view model, which forwards them from the audio pipeline.
    func testThePopoverSeesPlugsAndSelectionsThroughTheViewModel() {
        let settings = makeSettings()
        let viewModel = DictationViewModel(
            settings: settings,
            overlayBufferCoordinator: MockOverlayCoordinator(),
            startRuntimeServices: false,
            dependencies: .init(microphone: { FakeMicrophoneCaptureService() })
        )
        retainForTestProcessLifetime(viewModel)
        viewModel.fakeMicrophone.configureDevices([builtIn], defaultInputDeviceID: builtIn.id)
        viewModel.refreshMicrophoneInputs()
        XCTAssertEqual(viewModel.availableInputDevices, [builtIn])
        XCTAssertEqual(viewModel.selectedInputDeviceID, builtIn.id)

        viewModel.fakeMicrophone.configureDevices([builtIn, usb], defaultInputDeviceID: builtIn.id)
        // What the microphone's CoreAudio callback calls.
        viewModel.audio.handleMicrophoneInputDevicesChanged()
        XCTAssertEqual(viewModel.availableInputDevices, [builtIn, usb])

        viewModel.selectMicrophoneInput(id: usb.id)
        XCTAssertEqual(viewModel.selectedInputDeviceID, usb.id)
        XCTAssertEqual(settings.selectedInputDeviceUID, usb.id)
        XCTAssertEqual(viewModel.selectedInputDeviceChannelCount, 2)
    }

    private func makePipeline() -> (SessionAudioPipeline, SettingsStore) {
        let suiteName = "localvoxtral.MicrophoneHotPlugTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = SettingsStore(defaults: defaults, environment: [:], secretStore: InMemorySecretStore())
        let audio = SessionAudioPipeline(
            settings: settings,
            microphone: { FakeMicrophoneCaptureService() },
            ducksRealOutput: false
        )
        return (audio, settings)
    }
}
