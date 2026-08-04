import Foundation

#if canImport(Darwin)
import Darwin

/// Is a herdr client (app-mode `herdr` process) attached to this TTY device?
/// This is what binds "Ghostty's focused surface" to "herdr is what that
/// surface displays" — the socket API has no client introspection.
protocol HerdrClientTTYProbing: Sendable {
    func isHerdrClient(onTTYDevicePath: String) -> Bool
}

/// Same-user process-table probe used only after Ghostty positively identifies
/// its focused surface's TTY. Every metadata failure abstains; absence is safer
/// than treating an unrelated or unreadable surface as herdr.
enum HerdrClientTTYProbe {
    static func isHerdrClient(onTTYDevicePath path: String) -> Bool {
        isHerdrClient(
            onTTYDevicePath: path,
            deviceID: liveDeviceID,
            processNames: liveProcessNames
        )
    }

    static func isHerdrClient(
        onTTYDevicePath path: String,
        deviceID: @Sendable (String) -> dev_t?,
        processNames: @Sendable (dev_t) -> [String]?
    ) -> Bool {
        guard let device = deviceID(path),
              let names = processNames(device)
        else { return false }
        return names.contains("herdr")
    }

    /// Both live reads are the SHARED walk (`TTYProcessTable`), so this probe
    /// and the ssh-destination probe cannot drift apart on what "on this tty"
    /// means. The injected-seam signatures above are unchanged: this one only
    /// ever needs names, and says so by throwing the pids away here.
    private static let liveDeviceID: @Sendable (String) -> dev_t? = TTYProcessTable.liveDeviceID

    private static let liveProcessNames: @Sendable (dev_t) -> [String]? = { device in
        TTYProcessTable.entries(onDevice: device)?.map(\.name)
    }
}
#endif
