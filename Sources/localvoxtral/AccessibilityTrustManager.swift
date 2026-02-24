import AppKit
import ApplicationServices
import Foundation
import Observation

@MainActor
@Observable
final class AccessibilityTrustManager {
    typealias TrustChecker = () -> Bool
    typealias PermissionPrompter = () -> Void
    typealias SleepClosure = (Duration) async -> Void
    typealias DateProvider = () -> Date

    static let errorMessage =
        "Enable Accessibility for localvoxtral in System Settings > Privacy & Security > Accessibility."

    private(set) var isTrusted = false
    var lastError: String?

    var onTrustChanged: (() -> Void)?

    private var hasPromptedForPermission = false
    private var hasShownError = false
    private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private let trustChecker: TrustChecker
    @ObservationIgnored private let permissionPrompter: PermissionPrompter
    @ObservationIgnored private let sleepFor: SleepClosure
    @ObservationIgnored private let now: DateProvider
    @ObservationIgnored private let pollingInterval: Duration
    @ObservationIgnored private let pollingTimeoutSeconds: TimeInterval

    init(
        trustChecker: @escaping TrustChecker = { AXIsProcessTrusted() },
        permissionPrompter: @escaping PermissionPrompter = {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        },
        sleepFor: @escaping SleepClosure = { duration in
            try? await Task.sleep(for: duration)
        },
        now: @escaping DateProvider = Date.init,
        pollingInterval: Duration = .milliseconds(400),
        pollingTimeoutSeconds: TimeInterval = 90
    ) {
        self.trustChecker = trustChecker
        self.permissionPrompter = permissionPrompter
        self.sleepFor = sleepFor
        self.now = now
        self.pollingInterval = pollingInterval
        self.pollingTimeoutSeconds = max(0, pollingTimeoutSeconds)
    }

    func refresh() {
        let wasTrusted = isTrusted
        let trusted = trustChecker()
        if isTrusted != trusted {
            isTrusted = trusted
        }

        guard trusted else { return }
        pollingTask?.cancel()
        pollingTask = nil
        hasShownError = false
        if lastError == Self.errorMessage {
            lastError = nil
        }
        if !wasTrusted {
            onTrustChanged?()
        }
    }

    func requestPermission() {
        permissionPrompter()
        startPolling()
        refresh()
    }

    func promptIfNeeded() {
        guard !hasPromptedForPermission else { return }
        hasPromptedForPermission = true

        permissionPrompter()
        startPolling()
        refresh()
    }

    func setErrorIfNeeded() {
        guard !hasShownError else { return }
        hasShownError = true
        lastError = Self.errorMessage
    }

    func clearErrorIfNeeded() {
        refresh()
        guard hasShownError else { return }
        hasShownError = false
        if lastError == Self.errorMessage {
            lastError = nil
        }
    }

    func stopTasks() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Private

    private func startPolling() {
        guard !isTrusted else { return }
        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            guard let self else { return }
            let deadline = self.now().addingTimeInterval(self.pollingTimeoutSeconds)
            defer {
                self.pollingTask = nil
            }

            while !Task.isCancelled, self.now() < deadline {
                await self.sleepFor(self.pollingInterval)
                self.refresh()
                if self.isTrusted {
                    break
                }
            }
        }
    }
}
