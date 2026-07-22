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

    private static let liveDeviceID: @Sendable (String) -> dev_t? = { path in
        // `lstat`, matching ClaudeSocketGuard: `Darwin.stat` resolves to the
        // struct type, not the function, and a /dev node is never a symlink.
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return nil }
        return metadata.st_rdev
    }

    private static let liveProcessNames: @Sendable (dev_t) -> [String]? = { device in
        // dev_t is Int32 on Darwin, so this is an identity conversion today —
        // but if the type ever widens, a device that does not fit must abstain,
        // not trap mid-dictation.
        guard let deviceMib = Int32(exactly: device) else { return nil }
        var mib = [Int32(CTL_KERN), Int32(KERN_PROC), Int32(KERN_PROC_TTY), deviceMib]
        var byteCount = 0
        guard sysctl(&mib, u_int(mib.count), nil, &byteCount, nil, 0) == 0,
              byteCount > 0
        else { return nil }

        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](
            repeating: kinfo_proc(), count: (byteCount + stride - 1) / stride
        )
        var fetchedBytes = processes.count * stride
        let status = processes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &fetchedBytes, nil, 0)
        }
        guard status == 0 else { return nil }

        return processes.prefix(fetchedBytes / stride).map { process in
            // Bounded decode: `String(cString:)` would walk past the fixed-size
            // p_comm tuple if a corrupted entry ever arrived without its NUL.
            withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
    }
}
#endif
