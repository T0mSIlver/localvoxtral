import Foundation
import Synchronization
@testable import localvoxtral

/// A microphone that never touches CoreAudio or TCC: the permission it
/// reports, the devices it lists and the access requests it holds are the
/// test's to set. Injected through `DictationViewModel.Dependencies` and
/// reached back as `viewModel.fakeMicrophone`.
final class FakeMicrophoneCaptureService: MicrophoneCapturing, @unchecked Sendable {
    private struct State {
        var authorization: MicrophoneAuthorizationStatus = .authorized
        var devices: [MicrophoneInputDevice] = []
        var defaultInputDeviceID: String?
        var pendingAccessCompletions: [@Sendable (Bool) -> Void] = []
        var startCount = 0
        var stopCount = 0
        var isCapturing = false
        var lastPreferredDeviceID: String?
        var lastPreferredInputChannel = 0
        var onConfigurationChange: (@Sendable () -> Void)?
        var onInputDevicesChanged: (@Sendable () -> Void)?
        var onError: (@Sendable (String) -> Void)?
    }

    private let state = Mutex(State())

    /// The status `authorizationStatus()` reports. `requestAccess` with
    /// `.notDetermined` parks the completion in `pendingAccessCompletions`
    /// until `resolvePendingAccess`; any other status answers at once.
    var authorization: MicrophoneAuthorizationStatus {
        get { state.withLock { $0.authorization } }
        set { state.withLock { $0.authorization = newValue } }
    }

    var startCount: Int { state.withLock { $0.startCount } }
    var stopCount: Int { state.withLock { $0.stopCount } }
    var lastPreferredDeviceID: String? { state.withLock { $0.lastPreferredDeviceID } }
    var lastPreferredInputChannel: Int { state.withLock { $0.lastPreferredInputChannel } }
    var pendingAccessRequestCount: Int { state.withLock { $0.pendingAccessCompletions.count } }

    func configureDevices(_ devices: [MicrophoneInputDevice], defaultInputDeviceID: String?) {
        state.withLock {
            $0.devices = devices
            $0.defaultInputDeviceID = defaultInputDeviceID
        }
    }

    /// Answers every access request parked by `requestAccess`, oldest first.
    func resolvePendingAccess(granted: Bool) {
        let completions = state.withLock { state -> [@Sendable (Bool) -> Void] in
            let pending = state.pendingAccessCompletions
            state.pendingAccessCompletions = []
            if granted { state.authorization = .authorized }
            return pending
        }
        for completion in completions { completion(granted) }
    }

    // MARK: - MicrophoneCapturing

    var onConfigurationChange: (@Sendable () -> Void)? {
        get { state.withLock { $0.onConfigurationChange } }
        set { state.withLock { $0.onConfigurationChange = newValue } }
    }

    var onInputDevicesChanged: (@Sendable () -> Void)? {
        get { state.withLock { $0.onInputDevicesChanged } }
        set { state.withLock { $0.onInputDevicesChanged = newValue } }
    }

    var onError: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onError } }
        set { state.withLock { $0.onError = newValue } }
    }

    func authorizationStatus() -> MicrophoneAuthorizationStatus {
        authorization
    }

    func requestAccess(completion: @escaping @Sendable (Bool) -> Void) {
        let answer: Bool? = state.withLock { state in
            switch state.authorization {
            case .authorized: return true
            case .denied, .restricted: return false
            case .notDetermined:
                state.pendingAccessCompletions.append(completion)
                return nil
            }
        }
        if let answer { completion(answer) }
    }

    func availableInputDevices() -> [MicrophoneInputDevice] {
        state.withLock { $0.devices }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func defaultInputDeviceID() -> String? {
        state.withLock { $0.defaultInputDeviceID }
    }

    func start(
        preferredDeviceID: String?,
        preferredInputChannel: Int,
        chunkHandler _: @escaping MicrophoneCaptureService.ChunkHandler
    ) throws {
        state.withLock {
            $0.startCount += 1
            $0.isCapturing = true
            $0.lastPreferredDeviceID = preferredDeviceID
            $0.lastPreferredInputChannel = preferredInputChannel
        }
    }

    func stop() {
        state.withLock {
            $0.stopCount += 1
            $0.isCapturing = false
        }
    }

    func isCapturing() -> Bool { state.withLock { $0.isCapturing } }
    func hasRecentCapturedAudio(within _: TimeInterval) -> Bool { isCapturing() }
    func hasCapturedAudioInCurrentRun() -> Bool { isCapturing() }
    func resumeIfNeeded() -> Bool { false }
    func refreshInputTapIfNeeded() -> Bool { false }
}

extension DictationViewModel {
    /// The fake a test injected through `Dependencies.microphone`. Reaching it
    /// instantiates the lazy service, which is what a real session does too.
    @MainActor
    var fakeMicrophone: FakeMicrophoneCaptureService {
        guard let fake = microphone as? FakeMicrophoneCaptureService else {
            preconditionFailure("this view model was built without a FakeMicrophoneCaptureService")
        }
        return fake
    }
}
