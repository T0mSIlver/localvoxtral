import AVFoundation
import Foundation
import Observation
import os

/// A dictation's audio: the microphone (or, in a dogfood build, a file) that
/// feeds the chunk buffer, the send and commit loops that drain it to the
/// realtime client, the capture health monitor, output ducking, and the
/// input device list and selection the popover shows.
///
/// It decides nothing about the session. Restarting a dictation on another
/// input, and what the health monitor's findings do to the session, stay
/// with the view model, which forwards what the views read.
@MainActor
@Observable
final class SessionAudioPipeline {
    @ObservationIgnored
    let settings: SettingsStore

    private(set) var availableInputDevices: [MicrophoneInputDevice] = []
    private(set) var selectedInputDeviceID = ""

    /// `Dependencies.microphone`: nil is the CoreAudio service.
    @ObservationIgnored
    private let makeMicrophone: (() -> any MicrophoneCapturing)?
    /// True when a microphone was injected, which then answers every
    /// authorization question itself.
    var hasInjectedMicrophone: Bool { makeMicrophone != nil }

    @ObservationIgnored
    private(set) var hasInitializedMicrophone = false
    @ObservationIgnored
    lazy var microphone: any MicrophoneCapturing = {
        hasInitializedMicrophone = true
        return makeMicrophone?() ?? MicrophoneCaptureService()
    }()

    /// Ducks other audio for the length of a session. Assigned in `init` so
    /// its volume control can be the real CoreAudio one only in the app;
    /// `var` so a test can swap the whole controller.
    @ObservationIgnored
    var audioDucking: AudioDuckingController

    @ObservationIgnored
    let audioChunkBuffer = AudioChunkBuffer()
    @ObservationIgnored
    let healthMonitor = AudioCaptureHealthMonitor()
    @ObservationIgnored
    var commitTask: Task<Void, Never>?
    @ObservationIgnored
    var audioSendTask: Task<Void, Never>?

    #if LOCALVOXTRAL_DOGFOOD
    /// The WAV this launch dictates from in place of the microphone, or nil.
    /// `var` so tests name a file without touching the process environment.
    @ObservationIgnored
    var dogfoodAudioFileURL = DogfoodAudioFileSource.fileURL(
        fromEnvironment: ProcessInfo.processInfo.environment)
    @ObservationIgnored
    var dogfoodAudioFileSleep: DogfoodAudioFileSource.Sleep = { try await Task.sleep(for: $0) }
    @ObservationIgnored
    var dogfoodAudioFileSource: DogfoodAudioFileSource?
    #endif

    /// `ducksRealOutput` is false everywhere but the running app: a unit
    /// suite that reached the real control would move the volume of the Mac
    /// running the tests.
    init(
        settings: SettingsStore,
        microphone: (() -> any MicrophoneCapturing)?,
        ducksRealOutput: Bool
    ) {
        self.settings = settings
        self.makeMicrophone = microphone
        self.audioDucking = AudioDuckingController(
            volumeControl: ducksRealOutput
                ? CoreAudioSystemOutputVolumeControl()
                : UnavailableSystemOutputVolumeControl(),
            isEnabled: { settings.audioDuckingEnabled },
            fadeDuration: { settings.audioDuckingFadeDuration },
            interruptedDuck: { settings.audioDuckingPendingRestore },
            recordInterruptedDuck: { settings.audioDuckingPendingRestore = $0 }
        )
    }

    // MARK: - Capture

    /// A failed/cancelled connection can end before audio capture ever starts.
    /// Do not instantiate the lazy CoreAudio service merely to stop it: doing
    /// so registers device listeners that an app-lifetime view model then owns.
    func stopMicrophoneIfInitialized() {
        #if LOCALVOXTRAL_DOGFOOD
        stopDogfoodAudioFileSource()
        #endif
        guard hasInitializedMicrophone else { return }
        microphone.stop()
    }

    /// False only in a dogfood build launched with an audio file to dictate
    /// from: that session needs no microphone grant, and nothing may fall back
    /// to the microphone behind its back.
    var capturesFromMicrophone: Bool {
        #if LOCALVOXTRAL_DOGFOOD
        return dogfoodAudioFileURL == nil
        #else
        return true
        #endif
    }

    /// Starts whatever feeds this session's audio.
    func startSessionAudioCapture(
        preferredDeviceID: String?,
        chunkHandler: @escaping MicrophoneCaptureService.ChunkHandler
    ) throws {
        #if LOCALVOXTRAL_DOGFOOD
        if let dogfoodAudioFileURL {
            try startDogfoodAudioFileSource(dogfoodAudioFileURL, chunkHandler: chunkHandler)
            return
        }
        #endif
        try microphone.start(
            preferredDeviceID: preferredDeviceID,
            preferredInputChannel: selectedInputChannel,
            chunkHandler: chunkHandler
        )
    }

    /// Once this returns no further chunk reaches the session's handler.
    func stopSessionAudioCapture() {
        #if LOCALVOXTRAL_DOGFOOD
        stopDogfoodAudioFileSource()
        guard capturesFromMicrophone else { return }
        #endif
        microphone.stop()
    }

    func microphoneAuthorizationStatus() -> MicrophoneAuthorizationStatus {
        guard capturesFromMicrophone else { return .authorized }
        // A mere status read (the onboarding/General permission rows) must
        // not force the lazy CoreAudio service into existence; once the
        // service exists, or when one was injected, ask it, so the injected
        // replacement stays authoritative.
        guard hasInitializedMicrophone || hasInjectedMicrophone else {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .authorized
            case .denied:
                return .denied
            case .restricted:
                return .restricted
            case .notDetermined:
                return .notDetermined
            @unknown default:
                return .notDetermined
            }
        }
        return microphone.authorizationStatus()
    }

    // MARK: - Send and commit loops

    func restartCommitTask(
        client: any RealtimeClient,
        sleep: @escaping @Sendable (Duration) async -> Void
    ) {
        commitTask?.cancel()
        commitTask = nil

        let interval = TimingConstants.commitInterval
        guard client.supportsPeriodicCommit else { return }
        commitTask = Task(priority: .utility) {
            while !Task.isCancelled {
                await sleep(.seconds(interval))
                guard !Task.isCancelled else { break }
                client.sendCommit(final: false)
            }
        }
    }

    func restartAudioSendTask(
        client: any RealtimeClient,
        debugLoggingEnabled: Bool,
        sleep: @escaping @Sendable (Duration) async -> Void
    ) {
        audioSendTask?.cancel()

        let interval = TimingConstants.audioSendInterval
        let chunkBuffer = audioChunkBuffer
        audioSendTask = Task(priority: .utility) {
            var emptyBufferTicks = 0
            while !Task.isCancelled {
                await sleep(.seconds(interval))
                guard !Task.isCancelled else { break }

                // Read before draining: between the socket dying and the
                // `.disconnected` event cancelling this task, a tick that
                // drained would hand its chunk to a client that discards it —
                // and that audio is exactly what a reconnect replays (#380).
                guard client.isConnected else { continue }

                let bufferedChunk = chunkBuffer.takeAll()
                guard !bufferedChunk.isEmpty else {
                    emptyBufferTicks += 1
                    if debugLoggingEnabled, emptyBufferTicks % 20 == 0 {
                        Log.dictation.debug("audio send loop has no buffered chunks")
                    }
                    continue
                }
                emptyBufferTicks = 0
                client.sendAudioChunk(bufferedChunk)
            }
        }
    }

    func flushBufferedAudio(to client: any RealtimeClient) {
        let chunk = audioChunkBuffer.takeAll()
        guard !chunk.isEmpty else { return }
        client.sendAudioChunk(chunk)
    }

    /// Stops both loops. The buffer keeps what they had not drained.
    func cancelSendAndCommitTasks() {
        commitTask?.cancel()
        commitTask = nil
        audioSendTask?.cancel()
        audioSendTask = nil
    }

    // MARK: - Input devices

    /// CoreAudio reported a device plugged in, unplugged, or a new system
    /// default input.
    /// While a capture runs the health monitor owns the refresh: it compares
    /// the selection before and after to catch the live mic disappearing.
    /// Otherwise nobody is listening, so refresh here — without this a mic
    /// plugged in after launch stayed out of the menu until relaunch.
    func handleMicrophoneInputDevicesChanged() {
        if healthMonitor.isMonitoring {
            healthMonitor.handleInputDevicesChanged()
        } else {
            refreshMicrophoneInputs()
        }
    }

    func refreshMicrophoneInputs() {
        let devices = microphone.availableInputDevices()
        if availableInputDevices != devices {
            availableInputDevices = devices
        }

        let savedSelection = settings.selectedInputDeviceUID.trimmed
        let currentSelection = selectedInputDeviceID.trimmed
        let explicitSelection = !savedSelection.isEmpty ? savedSelection : currentSelection

        guard !devices.isEmpty else { return }

        if !explicitSelection.isEmpty,
           devices.contains(where: { $0.id == explicitSelection })
        {
            if selectedInputDeviceID != explicitSelection {
                selectedInputDeviceID = explicitSelection
            }
            if settings.selectedInputDeviceUID != explicitSelection {
                settings.selectedInputDeviceUID = explicitSelection
            }
            return
        }

        let resolvedSelection: String
        if let defaultID = microphone.defaultInputDeviceID(),
           devices.contains(where: { $0.id == defaultID })
        {
            resolvedSelection = defaultID
        } else if let firstDevice = devices.first {
            resolvedSelection = firstDevice.id
        } else {
            return
        }

        if selectedInputDeviceID != resolvedSelection {
            selectedInputDeviceID = resolvedSelection
        }
        // A saved mic that is only unplugged stays saved, so plugging it back
        // in selects it again. Only a first run with nothing saved records
        // the fallback.
        if savedSelection.isEmpty {
            settings.selectedInputDeviceUID = resolvedSelection
        }
    }

    /// Saves and selects `id`. True when the selection changed, which a
    /// running dictation has to be restarted for.
    @discardableResult
    func selectMicrophoneInput(id: String) -> Bool {
        guard !id.isEmpty else { return false }
        // Save even when `id` is already selected: it may be the fallback
        // standing in for an unplugged saved mic, and clicking it means
        // "use this one from now on".
        if settings.selectedInputDeviceUID != id {
            settings.selectedInputDeviceUID = id
        }
        guard selectedInputDeviceID != id else { return false }

        selectedInputDeviceID = id
        return true
    }

    /// Channels the selected input device reports. Above 2 the capture path
    /// picks ONE channel (there is no meaningful downmix), so the popover
    /// offers the choice; at or below 2 the picker stays hidden.
    var selectedInputDeviceChannelCount: UInt32 {
        availableInputDevices.first { $0.id == selectedInputDeviceID }?.channelCount ?? 1
    }

    var selectedInputChannel: Int {
        MicrophoneCaptureService.resolvedCaptureChannel(
            settings.selectedInputChannel,
            channelCount: AVAudioChannelCount(selectedInputDeviceChannelCount))
    }

    /// Saves `channel`. True when it changed, which a running dictation has
    /// to be restarted for.
    @discardableResult
    func selectMicrophoneInputChannel(_ channel: Int) -> Bool {
        guard channel >= 0, channel < Int(selectedInputDeviceChannelCount) else { return false }
        guard settings.selectedInputChannel != channel else { return false }

        settings.selectedInputChannel = channel
        return true
    }
}
