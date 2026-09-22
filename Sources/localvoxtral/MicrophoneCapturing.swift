import Foundation

/// What a dictation session asks of its audio source: permission, the input
/// devices, a start and a stop, and the health signals the capture monitor
/// reads. `MicrophoneCaptureService` is the CoreAudio implementation; a
/// dogfood build can dictate from a file through the same surface, and tests
/// inject `FakeMicrophoneCaptureService`.
protocol MicrophoneCapturing: AnyObject, Sendable {
    var onConfigurationChange: (@Sendable () -> Void)? { get set }
    var onInputDevicesChanged: (@Sendable () -> Void)? { get set }
    var onError: (@Sendable (String) -> Void)? { get set }

    func authorizationStatus() -> MicrophoneAuthorizationStatus
    func requestAccess(completion: @escaping @Sendable (Bool) -> Void)
    func availableInputDevices() -> [MicrophoneInputDevice]
    func defaultInputDeviceID() -> String?

    func start(
        preferredDeviceID: String?,
        preferredInputChannel: Int,
        chunkHandler: @escaping MicrophoneCaptureService.ChunkHandler
    ) throws
    func stop()

    func isCapturing() -> Bool
    func hasRecentCapturedAudio(within interval: TimeInterval) -> Bool
    func hasCapturedAudioInCurrentRun() -> Bool
    func resumeIfNeeded() -> Bool
    func refreshInputTapIfNeeded() -> Bool
}

extension MicrophoneCaptureService: MicrophoneCapturing {}
