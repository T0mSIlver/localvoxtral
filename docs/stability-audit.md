# Stability Audit — February 2026

## Critical (P0)

### 1. Data races in MicrophoneCaptureService
`@unchecked Sendable` with unprotected mutable fields: `tapInstalled`, `activeChunkHandler`, `configChangeObserver`, `didInstallInputDeviceListeners`, `previousDefaultInputDeviceObjectID`.

**Status: FIXED** — All mutable state moved behind `NSLock`-protected `ProtectedState` struct with `withState` accessor.

### 2. Silent audio pipeline failures
AVAudioConverter creation failure returned silently — chunk dropped, no user feedback.

**Status: FIXED** — Added `onError` callback to MicrophoneCaptureService; wired to `DictationViewModel.lastError` so users see a message.

### 3. No app lifecycle handling
No observers for sleep/wake/terminate. Audio engine and WebSocket persist through sleep.

**Status: FIXED** — Added `NSWorkspace.willSleepNotification` and `NSApplication.willTerminateNotification` observers that stop dictation gracefully.

### 4. Force downcast crash risk (TextInsertionService)
`focusedObject as! AXUIElement` — defended by CFGetTypeID check, but defense-in-depth.

**Status: REVIEWED** — CFGetTypeID guard makes this safe. Kept `as!` since `as?` generates an "always succeeds" warning. No change needed.

### 5. replaceSelectedTextRange AX retry
Called twice in sequence — appeared to risk double insertion but is actually an intentional retry: the Accessibility API can fail on the first attempt when the focused element's attribute state hasn't fully settled (common with larger text blocks from mlx-audio finalization).

**Status: REVIEWED** — Kept with explanatory comment. Removing the retry broke mlx-audio auto-paste.

## Important (P1)

### 6. Tasks cancelled but not awaited (DictationViewModel deinit)
`commitTask`, `audioSendTask`, `stopFinalizationTask` cancelled but never awaited.

**Status: OPEN** — Low risk in practice since tasks are lightweight polling loops. Awaiting in deinit requires restructuring to async cleanup.

### 7. No permission prompt timeout
`isAwaitingMicrophonePermission` stays true forever if user ignores dialog.

**Status: FIXED** — Added 120-second safety timeout that resets the flag.

### 8. No rate limiting on text insertion
`pendingRealtimeInsertionText` grows unbounded under burst conditions.

**Status: OPEN** — Low risk; insertion retry runs at 120ms and flushes all pending text each cycle.

### 9. No circuit breaker for insertion failures
Retry loop runs indefinitely at 120ms when Accessibility untrusted.

**Status: OPEN** — Mitigated by existing accessibility trust polling (90s timeout) and error display.

### 10. print() logging instead of os.log
No timestamps, log levels, or system log integration.

**Status: FIXED** — Replaced all `print()` logging with `os.Logger` via centralised `Log` enum. Supports Console.app filtering by subsystem/category.

### 11. No network change handling
No NWPathMonitor, no reconnection backoff.

**Status: FIXED** — Added `NetworkMonitor` wrapping `NWPathMonitor`. On network loss mid-dictation, dictation stops immediately and status shows "Network lost. Dictation stopped." On restore, status resets to "Ready". Starting dictation while offline is blocked with a clear message.

### 12. URL validation too permissive
Invalid URLs not caught until connection attempt.

**Status: OPEN** — Low risk; connection failure shows a clear error message.

## Minor (P2)

### 13. Unsafe index access (DictationViewModel)
`devices[0]` could crash if devices disconnect between guard and access.

**Status: FIXED** — Replaced with `devices.first` with early return.

### 14. Incomplete accessibility state cleanup
`hasShownAccessibilityError` not cleared when untrusted.

**Status: REVIEWED** — By design; the flag prevents re-showing the error while still untrusted. Clears when trust is granted.

### 15. Complex health monitor state
Overlapping boolean/date state vars instead of state machine enum.

**Status: OPEN** — Refactoring to a state machine would be a larger change with regression risk.

### 16. JSON parse errors swallowed
`try?` discards error; generic status emitted.

**Status: FIXED** — Replaced `try?` with `do/catch` that logs the actual parse error via `os.Logger` in both WebSocket clients.

### 17. Hardcoded timing constants
Scattered across files, not tunable without recompilation.

**Status: OPEN** — Low risk; these are tuned for the current audio pipeline and rarely need adjustment.

### 18. System-wide default input device manipulation
`MicrophoneCaptureService` changed the system-wide default input device to the user's preferred microphone, then restored it on stop. This activated other audio devices (e.g. headset mic) unnecessarily and affected other apps.

**Status: FIXED** — Replaced with `kAudioOutputUnitProperty_CurrentDevice` on the AVAudioEngine's input node audio unit. The system default is never touched; no restore needed on stop.

### 19. mlx-audio premature WebSocket disconnect during finalization
`disconnectAfterFinalCommitIfNeeded()` gave only a 2-second grace period, but mlx-audio server model inference on 6-12s of audio takes 5+ seconds, causing "no close frame received or sent" crashes and lost transcriptions.

**Status: FIXED** — `scheduleStopFinalization` now skips the premature disconnect for mlx-audio. The 7-second finalization timeout acts as the backstop.
