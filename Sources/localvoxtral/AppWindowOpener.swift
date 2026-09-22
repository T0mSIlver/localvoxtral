import Foundation

/// Opens the app's one window and does not believe it happened until the
/// window is on screen.
///
/// The window belongs to a SwiftUI `Settings` scene, which AppKit reaches
/// through the `showSettingsWindow:` action. Sent from inside
/// `applicationDidFinishLaunching`, that action is ACCEPTED — something in the
/// responder chain answers it — and no window appears: the scene is not ready
/// to act on it yet, and the send is lost with nothing to report (hand-checked
/// on the packaged build, #449). Deferring it one runloop turn is not enough
/// either, so the send is retried on a bounded schedule until the window shows
/// up, and the app says so in the log when it never does.
///
/// Every dependency is a closure so the schedule can be tested without a
/// window server, which the build host does not have.
@MainActor
struct AppWindowOpener {
    /// Sends the action that asks for the window.
    let show: () -> Void
    /// Whether the window is on screen now.
    let isOnScreen: () -> Bool
    let sleepFor: (Duration) async -> Void

    /// Enough to cover a slow launch, short enough that a user who asked for
    /// the window at launch sees it arrive with the app rather than later.
    static let attemptLimit = 8
    static let interval = Duration.milliseconds(250)

    /// Asks until the window is there. Returns the attempt that worked, or nil
    /// if the window never appeared.
    ///
    /// The first ask is unconditional, window on screen or not: the menu bar
    /// item's History and the onboarding Engines link come through here while
    /// the window may be open behind another app, and they have to bring it
    /// forward.
    func open() async -> Int? {
        for attempt in 1...Self.attemptLimit {
            show()
            if isOnScreen() { return attempt }
            await sleepFor(Self.interval)
            if isOnScreen() { return attempt }
        }
        return nil
    }
}
