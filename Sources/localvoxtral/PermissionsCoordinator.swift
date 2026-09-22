import Foundation
import Observation

/// What the permission prompts and refreshes ask of the session they report
/// into. `DictationViewModel` adopts it.
@MainActor
protocol PermissionSessionControlling: AnyObject {
    var isDictating: Bool { get }
    var isConnectingRealtimeSession: Bool { get }
    var isFinalizingStop: Bool { get }
    var isAwaitingMicrophonePermission: Bool { get set }
    var statusText: String { get set }
    var lastError: String? { get set }
    var currentStatusToken: DictationViewModel.StatusToken { get }
    var currentErrorToken: DictationViewModel.ErrorToken? { get }
    var capturesFromMicrophone: Bool { get }
    var microphone: any MicrophoneCapturing { get }
    func currentMicrophoneAuthorizationStatus() -> MicrophoneAuthorizationStatus
    func prepareLLMPolishingPromptAccessIfNeeded()
    func debugLog(_ message: String)
}

/// Microphone and Accessibility permissions: the startup prompt pass, the
/// requests the permission rows make, and the observable mirrors the rows
/// read. Owned by `DictationViewModel` and reached as `viewModel.permissions`.
/// It reports into the session through `PermissionSessionControlling`,
/// installed by the owner once it exists; with no owner a call logs and
/// returns.
@MainActor
@Observable
final class PermissionsCoordinator {
    @ObservationIgnored
    let settings: SettingsStore
    @ObservationIgnored
    let textInsertion: TextInsertionService
    @ObservationIgnored
    private let managesRuntimeServices: Bool
    @ObservationIgnored
    private let suppressStartupPermissionPrompts: Bool
    @ObservationIgnored
    private weak var owner: (any PermissionSessionControlling)?

    /// Observable mirror of the live microphone authorization status, refreshed
    /// on demand via `refreshMicrophonePermissionState()`. Stored (rather than
    /// read live) so permission UI re-renders when the grant changes while the
    /// app is foregrounded. Seeded lazily — reading the real status touches the
    /// microphone service, so it stays `.notDetermined` until the first refresh.
    var microphoneAuthorizationStatus: MicrophoneAuthorizationStatus = .notDetermined
    @ObservationIgnored
    private(set) var startupPermissionTask: Task<Void, Never>?
    @ObservationIgnored
    private(set) var hasRequestedStartupPermissions = false

    init(
        settings: SettingsStore,
        textInsertion: TextInsertionService,
        managesRuntimeServices: Bool,
        suppressStartupPermissionPrompts: Bool
    ) {
        self.settings = settings
        self.textInsertion = textInsertion
        self.managesRuntimeServices = managesRuntimeServices
        self.suppressStartupPermissionPrompts = suppressStartupPermissionPrompts
    }

    func install(session: any PermissionSessionControlling) {
        owner = session
    }

    func cancelTasks() {
        startupPermissionTask?.cancel()
    }

    private func noteNoOwner(_ what: String) {
        Log.dictation.error("permissions: \(what, privacy: .public) reached no session owner; nothing happened")
    }

    func requestStartupPermissionsIfNeeded() {
        guard let session = owner else { return noteNoOwner("\(#function)") }
        guard managesRuntimeServices else { return }
        guard !suppressStartupPermissionPrompts else {
            // .notice so the line persists in the unified log archive: it is
            // the after-the-fact field proof that a CI smoke launch skipped
            // the prompt pass (.info survives only in the memory buffer).
            Log.dictation.notice(
                "startup permission prompts suppressed (LOCALVOXTRAL_SUPPRESS_STARTUP_PERMISSION_PROMPTS=1)"
            )
            return
        }
        guard settings.onboardingCompleted else {
            session.debugLog("startup permission prompts skipped until onboarding completes")
            return
        }
        guard !hasRequestedStartupPermissions else { return }
        hasRequestedStartupPermissions = true

        startupPermissionTask?.cancel()
        startupPermissionTask = Task { @MainActor [weak self] in
            // The owner is looked up when the task runs, not when it is
            // queued: a view model released in between stays released.
            guard let self, let session = self.owner else { return }
            session.prepareLLMPolishingPromptAccessIfNeeded()
            guard !Task.isCancelled else { return }
            await self.requestStartupMicrophonePermissionIfNeeded()
            guard !Task.isCancelled else { return }
            self.requestStartupAccessibilityPermissionIfNeeded()
        }
    }

    func requestStartupAccessibilityPermissionIfNeeded() {
        guard let session = owner else { return noteNoOwner("\(#function)") }
        refreshAccessibilityTrustState()
        guard !textInsertion.isAccessibilityTrusted else { return }

        session.debugLog("startup accessibility permission prompt requested")
        textInsertion.requestAccessibilityPermissionIfNeeded()
    }

    func requestStartupMicrophonePermissionIfNeeded() async {
        guard let session = owner else { return noteNoOwner("\(#function)") }
        guard !session.isAwaitingMicrophonePermission else { return }
        guard session.capturesFromMicrophone else { return }
        guard session.microphone.authorizationStatus() == .notDetermined else { return }

        session.isAwaitingMicrophonePermission = true
        session.debugLog("startup microphone permission prompt requested")

        let granted = await withCheckedContinuation { continuation in
            session.microphone.requestAccess { granted in
                continuation.resume(returning: granted)
            }
        }

        guard !Task.isCancelled else { return }
        session.isAwaitingMicrophonePermission = false
        session.debugLog("startup microphone permission result granted=\(granted)")

        guard granted else {
            if !session.isDictating, !session.isFinalizingStop, !session.isConnectingRealtimeSession {
                session.statusText = DictationViewModel.StatusStrings.microphoneAccessDenied
            }
            session.lastError = DictationViewModel.microphoneDeniedMessage
            return
        }

        if !session.isDictating, !session.isFinalizingStop, !session.isConnectingRealtimeSession,
           session.currentStatusToken == .awaitingMicrophonePermission
        {
            session.statusText = DictationViewModel.StatusStrings.ready
        }
    }

    func requestAccessibilityPermission() {
        guard let session = owner else { return noteNoOwner("\(#function)") }
        textInsertion.requestAccessibilityPermission()

        if textInsertion.isAccessibilityTrusted {
            session.statusText = DictationViewModel.StatusStrings.ready
        } else {
            session.statusText = DictationViewModel.StatusStrings.waitingForAccessibilityPermission
        }
    }

    /// Re-read the live microphone authorization status into the observable
    /// mirror. Reading only — never prompts. Call on appear / app activation so
    /// permission rows reflect grants made in System Settings.
    func refreshMicrophonePermissionState() {
        guard let session = owner else { return noteNoOwner("\(#function)") }
        let status = session.currentMicrophoneAuthorizationStatus()
        if microphoneAuthorizationStatus != status {
            microphoneAuthorizationStatus = status
        }
    }

    /// Prompt for microphone access if it has not been decided yet. When access
    /// was already denied/restricted the system dialog no longer appears, so the
    /// permission UI routes the user to System Settings instead. Refreshes the
    /// observable status once the request resolves.
    func requestMicrophonePermission() {
        guard let session = owner else { return noteNoOwner("\(#function)") }
        session.microphone.requestAccess { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMicrophonePermissionState()
            }
        }
    }

    func refreshAccessibilityTrustState() {
        guard let session = owner else { return noteNoOwner("\(#function)") }
        let wasTrusted = textInsertion.isAccessibilityTrusted
        textInsertion.refreshAccessibilityTrustState()

        if textInsertion.isAccessibilityTrusted, !wasTrusted, !session.isDictating,
           (session.currentStatusToken == .waitingForAccessibilityPermission
               || session.currentStatusToken == .pasteBlockedByAccessibilityPermission)
        {
            session.statusText = DictationViewModel.StatusStrings.ready
        }

        if let axError = textInsertion.lastAccessibilityError {
            if session.lastError == nil || session.currentErrorToken == .accessibilityPermissionRequired {
                session.lastError = axError
            }
        } else if session.currentErrorToken == .accessibilityPermissionRequired {
            session.lastError = nil
        }
    }
}
