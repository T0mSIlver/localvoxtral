import ClaudeContextWire
import Foundation

extension ClaudeIntegrationSettingsModel {
    // MARK: - Screenshot preview

    /// Hidden debug default that arms the sample enrollment sheet.
    ///
    /// `debug.` prefixed like `debug.log_realtime_deltas`: not a product
    /// preference, no UI, and never surfaced in Settings. It exists so
    /// `scripts/capture-readme-assets.sh` can photograph a sheet that would
    /// otherwise require enrolling a real host and burning a real token.
    public static let enrollmentSheetPreviewDefaultsKey = "debug.enrollment_sheet_preview"

    public static func isEnrollmentSheetPreviewArmed(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: Self.enrollmentSheetPreviewDefaultsKey)
    }

    /// Present a sample sheet for screenshots.
    ///
    /// Nothing here is real: the host is not in the registry, the token is
    /// visibly fake, and `isPreview` makes every mutating entry point refuse.
    /// A preview therefore cannot write `~/.ssh/config`, spawn ssh, or change
    /// the enrolled-host list — the guards are in the model, so the view cannot
    /// forget one.
    public func presentPreviewPlan() {
        guard presentedPlan == nil else { return }
        let host = ClaudeRemoteHost(
            id: "preview0",
            label: "build-host",
            sshHostAlias: "build-host",
            createdAt: Date(timeIntervalSince1970: 0),
            lastSeenAt: nil,
            revokedAt: nil
        )
        // Token-shaped so the sheet's layout is honest, and unmistakably not a
        // credential. It is long enough for `ClaudeRemoteTokenRedaction` to
        // treat it as one, so the step-2 preview redacts it exactly as it would
        // redact a real token.
        let token = "lvx-preview-" + String(repeating: "0", count: 31)
        guard let plan = try? ClaudeRemoteEnrollmentService.plan(
            host: host,
            sshHostAlias: "build-host",
            listenerPort: listener?.boundPort ?? ClaudeRemoteListenerLimits.default.port,
            remoteForwardPort: remoteForwardPort
        ) else { return }
        enrollmentConfirmation = nil
        verificationChecks = []
        presentedPlan = EnrollmentPresentation(
            host: host,
            token: token,
            sshHostAlias: "build-host",
            plan: plan,
            isRotation: false,
            remoteForwardPort: remoteForwardPort,
            isPreview: true
        )
        Log.claudeContext.info("Claude remote enrollment sheet presented in preview mode")
    }
}
