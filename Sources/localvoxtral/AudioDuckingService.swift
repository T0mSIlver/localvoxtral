import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Ducks audio when dictation starts and restores when it stops.
///
/// Uses a multi-strategy approach since not all audio output devices
/// support software volume control (e.g. HDMI/DisplayPort monitors):
///
/// 1. Try CoreAudio VirtualMainVolume (headphones, built-in speakers)
/// 2. Duck DDC monitor volume via BetterDisplay binary (when `useDDC` is true and BetterDisplay is installed)
/// 3. Fall back to pausing common music apps (Spotify, Music) via NSAppleScript
/// 4. Resume paused apps on unduck
final class AudioDuckingService: @unchecked Sendable {
    private let lock = NSLock()
    private var _originalVolume: Float?
    private var _duckedVolume: Float?
    private var _fadeTask: Task<Void, Never>?
    private var _pausedApps: [String] = []
    private var _volumeControlAvailable = false
    private var _ddcOriginalVolume: Float?
    private var _ddcDuckedVolume: Float?
    private var _ddcDucked = false
    /// Incremented on every duck/unduck to cancel stale fade loops.
    private var _fadeGeneration: Int = 0

    // MARK: - DDC (BetterDisplay)

    static let betterDisplayPath = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay"

    static func isBetterDisplayInstalled() -> Bool {
        FileManager.default.fileExists(atPath: betterDisplayPath)
    }

    /// Duck all DDC-capable monitor volumes to `targetFraction` of current.
    /// Returns true if DDC ducking succeeded (at least one monitor responded).
    @discardableResult
    func duckViaDDC(to targetFraction: Float) -> Bool {
        guard Self.isBetterDisplayInstalled() else { return false }

        // Get current volume(s)
        guard let current = runBetterDisplay(args: ["get", "-volume"]),
              !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        // BetterDisplay returns comma-separated values for multiple monitors.
        // Parse the first value to determine the original level.
        let parts = current.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",")
            .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard let firstVolume = parts.first, firstVolume > 0 else { return false }

        // Use stored original if available (survives mid-fade re-ducks)
        lock.lock()
        let baseVolume = _ddcOriginalVolume ?? firstVolume
        if _ddcOriginalVolume == nil {
            _ddcOriginalVolume = firstVolume
        }
        lock.unlock()

        let targetVolume = baseVolume * max(0.0, min(1.0, targetFraction))
        let targetString = String(format: "%.4f", targetVolume)

        guard runBetterDisplay(args: ["set", "-volume=\(targetString)"]) != nil else {
            return false
        }

        lock.lock()
        _ddcDuckedVolume = targetVolume
        _ddcDucked = true
        lock.unlock()
        return true
    }

    /// Restore DDC monitor volume to what it was before ducking.
    /// - Parameter fadeInDuration: Seconds over which to fade volume back up.
    ///   DDC commands are slower than CoreAudio (process spawn per step),
    ///   so we use ~15 steps regardless of duration.
    func unduckViaDDC(fadeInDuration: TimeInterval = 1.5) {
        lock.lock()
        let original = _ddcOriginalVolume
        let duckedVolume = _ddcDuckedVolume
        // Don't clear _ddcOriginalVolume yet — if fade is cancelled by a new duck,
        // the true original must survive. Cleared on fade completion only.
        _ddcDuckedVolume = nil
        _ddcDucked = false
        _fadeGeneration += 1
        let myGeneration = _fadeGeneration
        lock.unlock()

        guard let original, Self.isBetterDisplayInstalled() else { return }

        let startVolume = duckedVolume ?? 0
        let steps = 15
        let stepInterval = fadeInDuration / Double(steps)

        Log.ducking.info("unduck: strategy=DDC fade from \(startVolume) to \(original) over \(fadeInDuration)s (\(steps) steps)")

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            for step in 1...steps {
                // Bail if a new duck/unduck started
                guard let self else { return }
                self.lock.lock()
                let stillCurrent = self._fadeGeneration == myGeneration
                self.lock.unlock()
                guard stillCurrent else {
                    Log.ducking.info("unduck: DDC fade cancelled at step \(step)/\(steps)")
                    return
                }

                let progress = Float(step) / Float(steps)
                let eased = progress * progress * (3.0 - 2.0 * progress)
                let volume = startVolume + (original - startVolume) * eased
                let volumeString = String(format: "%.4f", volume)
                _ = self.runBetterDisplay(args: ["set", "-volume=\(volumeString)"])
                if step < steps {
                    Thread.sleep(forTimeInterval: stepInterval)
                }
            }
            // Fade completed — safe to clear the true original
            if let self {
                self.lock.lock()
                if self._fadeGeneration == myGeneration {
                    self._ddcOriginalVolume = nil
                }
                self.lock.unlock()
            }
            Log.ducking.info("unduck: DDC fade complete")
        }
    }

    @discardableResult
    private func runBetterDisplay(args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.betterDisplayPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // suppress stderr

        process.launch()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static let defaultFadeDuration: TimeInterval = 0.3
    private static let fadeStepInterval: TimeInterval = 0.03

    private static let musicApps: [(name: String, pause: String, resume: String, state: String)] = [
        ("Spotify",
         "tell application \"Spotify\" to pause",
         "tell application \"Spotify\" to play",
         "tell application \"Spotify\" to player state as string"),
        ("Music",
         "tell application \"Music\" to pause",
         "tell application \"Music\" to play",
         "tell application \"Music\" to player state as string"),
    ]

    /// Duck audio to the target level.
    ///
    /// Strategy order:
    /// 1. CoreAudio VirtualMainVolume (headphones, built-in speakers) — smooth fade
    /// 2. DDC monitor volume via BetterDisplay (HDMI/DisplayPort) — when `useDDC` is true
    /// 3. Pause music apps (Spotify, Music) — final fallback
    func duck(to targetFraction: Float, useDDC: Bool = true) {
        lock.lock()
        _fadeTask?.cancel()
        _fadeGeneration += 1 // cancel any in-progress fade
        _pausedApps = []
        _volumeControlAvailable = false
        _duckedVolume = nil
        _ddcDucked = false
        // NOTE: _ddcOriginalVolume and _originalVolume are NOT cleared here.
        // They persist across duck/unduck cycles so mid-fade re-ducks don't
        // lose the true original volume. Cleared on fade completion only.

        if let deviceID = defaultOutputDeviceID(),
           let currentVolume = getVolume(deviceID: deviceID)
        {
            // Strategy 1: CoreAudio volume control works — use smooth fade
            _volumeControlAvailable = true
            if _originalVolume == nil {
                _originalVolume = currentVolume
            }
            let baseVolume = _originalVolume ?? currentVolume
            let targetVolume = baseVolume * max(0.0, min(1.0, targetFraction))
            _duckedVolume = targetVolume
            let startVolume = currentVolume
            lock.unlock()

            Log.ducking.info("duck: strategy=CoreAudio from=\(startVolume) to=\(targetVolume) device=\(deviceID)")

            let task = Task.detached { [weak self] in
                guard let self else { return }
                await self.fadeVolume(
                    deviceID: deviceID,
                    from: startVolume,
                    to: targetVolume
                )
            }

            lock.lock()
            _fadeTask = task
            lock.unlock()
        } else {
            lock.unlock()
            // Strategy 2: Try DDC via BetterDisplay
            if useDDC, duckViaDDC(to: targetFraction) {
                // DDC succeeded — nothing more to do
            } else {
                // Strategy 3: No volume control at all — pause music apps
                pauseRunningMusicApps()
            }
        }
    }

    /// Restore volume or resume paused music apps.
    /// - Parameter fadeInDuration: Duration in seconds for the volume fade-in.
    ///   Longer values produce a gentler return (useful for AirPods after long sessions).
    func unduck(fadeInDuration: TimeInterval = 1.5) {
        lock.lock()
        _fadeTask?.cancel()
        _fadeGeneration += 1
        let myGeneration = _fadeGeneration

        if _volumeControlAvailable, let originalVolume = _originalVolume,
           let deviceID = defaultOutputDeviceID()
        {
            // Reverse strategy 1: fade CoreAudio volume back up
            let startVolume = _duckedVolume ?? getVolume(deviceID: deviceID) ?? originalVolume
            // Don't clear _originalVolume yet — cleared on fade completion only.
            _duckedVolume = nil
            _volumeControlAvailable = false
            lock.unlock()

            Log.ducking.info(
                "unduck: strategy=CoreAudio start=\(startVolume) end=\(originalVolume) duration=\(fadeInDuration)s"
            )

            setVolume(deviceID: deviceID, volume: startVolume)

            let steps = max(1, Int(fadeInDuration / Self.fadeStepInterval))
            let stepInterval = Self.fadeStepInterval
            let capturedStart = startVolume
            let capturedEnd = originalVolume
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                for step in 1...steps {
                    guard let self else { return }
                    self.lock.lock()
                    let stillCurrent = self._fadeGeneration == myGeneration
                    self.lock.unlock()
                    guard stillCurrent else { return }

                    let progress = Float(step) / Float(steps)
                    let eased = progress * progress * (3.0 - 2.0 * progress)
                    let volume = capturedStart + (capturedEnd - capturedStart) * eased
                    self.setVolume(deviceID: deviceID, volume: volume)
                    Thread.sleep(forTimeInterval: stepInterval)
                }
                guard let self else { return }
                self.setVolume(deviceID: deviceID, volume: capturedEnd)
                self.lock.lock()
                if self._fadeGeneration == myGeneration {
                    self._originalVolume = nil
                }
                self.lock.unlock()
            }
        } else if _ddcDucked {
            // Reverse strategy 2: restore DDC monitor volume with fade
            _originalVolume = nil
            _volumeControlAvailable = false
            lock.unlock()
            unduckViaDDC(fadeInDuration: fadeInDuration)
        } else {
            // Reverse strategy 3: resume paused music apps
            Log.ducking.info("unduck: strategy=MusicApps (instant)")
            _originalVolume = nil
            _volumeControlAvailable = false
            let appsToResume = _pausedApps
            _pausedApps = []
            lock.unlock()
            resumeMusicApps(appsToResume)
        }
    }

    func cancelFade() {
        lock.lock()
        _fadeTask?.cancel()
        _fadeTask = nil
        lock.unlock()
    }

    // MARK: - Music App Control

    private func pauseRunningMusicApps() {
        for app in Self.musicApps {
            guard isAppRunning(app.name) else { continue }

            if let state = runAppleScript(app.state),
               state.lowercased().contains("playing")
            {
                _ = runAppleScript(app.pause)
                lock.lock()
                _pausedApps.append(app.name)
                lock.unlock()
            }
        }
    }

    private func resumeMusicApps(_ apps: [String]) {
        for appName in apps {
            guard let app = Self.musicApps.first(where: { $0.name == appName }) else {
                continue
            }
            guard isAppRunning(appName) else { continue }
            _ = runAppleScript(app.resume)
        }
    }

    private func isAppRunning(_ name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.localizedName == name && !app.isTerminated
        }
    }

    private func runAppleScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        return result?.stringValue
    }

    // MARK: - Volume Fade

    private func fadeVolume(
        deviceID: AudioDeviceID,
        from startVolume: Float,
        to endVolume: Float,
        duration: TimeInterval = 0.3
    ) async {
        let stepDuration = Self.fadeStepInterval
        let steps = max(1, Int(duration / stepDuration))

        for step in 1...steps {
            guard !Task.isCancelled else { return }

            let progress = Float(step) / Float(steps)
            let easedProgress = progress * progress * (3.0 - 2.0 * progress)
            let volume = startVolume + (endVolume - startVolume) * easedProgress

            setVolume(deviceID: deviceID, volume: volume)
            try? await Task.sleep(for: .seconds(stepDuration))
        }

        if !Task.isCancelled {
            setVolume(deviceID: deviceID, volume: endVolume)
        }
    }

    // MARK: - CoreAudio

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private func getVolume(deviceID: AudioDeviceID) -> Float? {
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &volume
        )

        guard status == noErr else { return nil }
        return volume
    }

    private func setVolume(deviceID: AudioDeviceID, volume: Float) {
        var mutableVolume = max(0.0, min(1.0, volume))
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, size, &mutableVolume
        )
    }
}
