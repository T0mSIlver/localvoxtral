import ClaudeContextWire
import Foundation

#if canImport(Darwin)
import Darwin
import Synchronization
#endif

extension ClaudeIntegrationSettingsModel {
    /// Re-read the listener's rejection counters.
    ///
    /// Deliberately part of `refreshHosts` rather than a timer of its own: that
    /// is what the pane already calls on appear and after every host action, and
    /// a background timer redrawing Settings is a cost with no reader.
    public func refreshRejectionHint() {
        guard let listener else {
            rejectionHint = nil
            return
        }
        rejectionHint = Self.rejectionHint(for: listener.rejectionSnapshot)
    }

    /// One sentence naming the likely cause, or nil when nothing was rejected.
    ///
    /// Short by owner rule — a Settings row has the same "no long text" problem
    /// the popover does — and count-free on purpose: the number of rejections is
    /// noise (a busy session produces one every few minutes), while WHICH KIND
    /// they were is the whole diagnosis. The detail stays in the log.
    ///
    /// The hedge in "a host MAY have" is deliberate. An enrolled host is not the
    /// only thing that can reach a loopback port, and a rejection carries no
    /// identity — only a shape.
    ///
    /// What the hedge no longer has to cover is the anonymous caller. A probe or
    /// a `curl` with no `Authorization` header used to land in the same category
    /// as a pre-1.1.0 plugin, so checking your own setup raised a hint accusing
    /// a healthy host; those are now `.absentAuthorization`, which
    /// `Snapshot.isEmpty` excludes and this sentence therefore never describes.
    static func rejectionHint(for snapshot: ClaudeRemoteRejectionTally.Snapshot) -> String? {
        guard !snapshot.isEmpty else { return nil }
        let cause: String
        switch (snapshot.emptyCredential > 0, snapshot.unknownToken > 0) {
        case (true, true):
            cause = "an outdated plugin or a stale token"
        case (true, false):
            return "Rejected connections suggest an outdated plugin; use Update host."
        case (false, true):
            return "Rejected connections suggest a stale token; rotate it and rerun setup."
        case (false, false):
            cause = "a malformed authorization header"
        }
        return "Rejected connections suggest \(cause)."
    }

    public func refreshListenerStatus() {
        guard let listener else { return }
        if listener.isListening {
            listenerStatus = .listening(port: listener.boundPort)
        } else if listenerStatus.isFailure {
            // Preserve a failure we already diagnosed: "not listening" is the
            // symptom, and overwriting the cause with it is how a port conflict
            // turns into a shrug.
            return
        } else {
            listenerStatus = .idle
        }
    }

    /// Retry a failed bind. The user's move after freeing the port.
    public func retryListener() {
        listenerStatus = .idle
        reconcileListener()
    }

    /// Reconcile during app launch without queueing a modal alert for a window
    /// that does not exist yet. The status row and log still retain the exact
    /// failure; opening Settings later shows the remedy and Retry in context.
    public func synchronizeListenerAtLaunch() {
        reconcileListener(presentAlert: false)
    }

    func reconcileListener(presentAlert: Bool = true) {
        guard let listener else { return }
        // Shutdown is the MIRROR of startup, and this is the shutdown case:
        // revoking the last host is about to close the port, so the forwards
        // into it come down first. Reversed — the documented order everywhere
        // else in this feature — a hook arriving during `listener.stop()` rides
        // a live tunnel into a socket that is already gone, and the Mac's ssh
        // client answers it by printing `connect_to … failed.` into the user's
        // remote terminal.
        if listener.isListening, registry?.hasActiveHosts != true {
            forwards?.stopAll()
        }
        do {
            try listener.reconcile()
            listenerStatus = listener.isListening ? .listening(port: listener.boundPort) : .idle
            // Listener FIRST, forwards second — always, including here. A
            // forward opened before the bind terminates at a closed port: the
            // hooks get connection-refused and fail open (silently), while
            // ssh on this Mac prints `connect_to … failed.` into the user's
            // remote terminal on every dial. The coordinator enforces the same
            // rule itself by refusing to run while the listener is unbound;
            // this ordering is what makes the enabled case take effect without
            // a relaunch.
            forwards?.reconcile()
        } catch {
            // A listener that failed to bind must not leave forwards running
            // into a dead port.
            forwards?.stopAll()
            listenerStatus = Self.status(for: error, port: listener.boundPort)
            if presentAlert {
                alert = DetailAlert(
                    title: "Remote Claude Code context",
                    detail: Self.listenerFailureDetail(error, port: listener.boundPort)
                )
            }
            Log.claudeContext.error(
                "Claude remote listener reconcile failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    static func status(for error: any Error, port: UInt16) -> ListenerStatus {
        if case .bindFailed(let code)? = error as? ClaudeRemoteContextListener.StartFailure,
           code == EADDRINUSE {
            return .portConflict(port: port)
        }
        return .failed
    }

    static func listenerFailureDetail(_ error: any Error, port: UInt16) -> String {
        if case .bindFailed(let code)? = error as? ClaudeRemoteContextListener.StartFailure,
           code == EADDRINUSE {
            return "localvoxtral could not bind 127.0.0.1:\(port), because something else already has it.\n\n"
                + "This is usually a second copy of localvoxtral. Note that a squatter on this port would "
                + "receive your remote hosts' context. It cannot authenticate them because it does not have the "
                + "token hashes), but it does see what they send before the request is rejected. Find and "
                + "quit whatever holds the port rather than moving off it.\n\n"
                + "`lsof -nP -iTCP:\(port) -sTCP:LISTEN` will name the process."
        }
        return String(describing: error)
    }
}
