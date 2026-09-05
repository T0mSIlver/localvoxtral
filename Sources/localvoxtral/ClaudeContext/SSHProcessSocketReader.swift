import ClaudeContextWire
import Foundation

#if canImport(Darwin)
import Darwin

/// One ESTABLISHED TCP connection held by a process, as this machine's kernel
/// describes it.
///
/// The local half of the plain-ssh join binding. `localPort` is the ephemeral
/// port OUR kernel picked for the connection; `peerPort`/`peerAddress` are
/// where it goes. Nothing here is ever dialed — the type exists to be compared
/// against what a remote session says its `$SSH_CONNECTION` is.
struct SSHClientSocket: Sendable, Equatable {
    /// Host byte order, already converted from the kernel's network order.
    var localPort: UInt16
    var peerPort: UInt16
    /// `inet_ntop`'s canonical text for the peer address. Compared through
    /// `SSHConnectionAddressMatch.sameAddress`, never as a string.
    var peerAddress: String

    init(localPort: UInt16, peerPort: UInt16, peerAddress: String) {
        self.localPort = localPort
        self.peerPort = peerPort
        self.peerAddress = peerAddress
    }
}

/// Are two textual IP addresses the same address?
///
/// String equality is not the test: the kernel and sshd can spell one address
/// differently and both be right. `::1` and `0:0:0:0:0:0:0:1` are the same
/// IPv6 address, and an IPv4 connection accepted on a dual-stack listener is
/// reported by the client's socket as the IPv4-mapped `::ffff:10.0.0.9` while
/// sshd — which reads its own `AF_INET` peer — writes `10.0.0.9` into
/// `SSH_CONNECTION`. Comparing text would abstain on the ordinary case.
///
/// So both sides are parsed to BYTES with `inet_pton`, IPv4-mapped IPv6 is
/// unwrapped to its four v4 bytes, and the bytes are compared. Anything that
/// does not parse compares equal to nothing at all — a malformed address from
/// the remote host abstains the join rather than matching loosely.
enum SSHConnectionAddressMatch {
    /// The address as bytes: 4 for IPv4, 16 for IPv6, and IPv4-mapped IPv6
    /// (`::ffff:a.b.c.d`) folded to its 4 v4 bytes so the two families can
    /// meet. Nil for anything `inet_pton` refuses.
    static func addressBytes(_ text: String) -> [UInt8]? {
        guard !text.isEmpty,
              text.utf8.count <= ClaudeRemoteSSHConnectionReport.maxAddressLength
        else { return nil }

        var v4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return withUnsafeBytes(of: v4.s_addr) { Array($0) }
        }
        var v6 = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        guard bytes.count == 16 else { return nil }
        return unwrappingIPv4Mapped(bytes)
    }

    /// `::ffff:a.b.c.d` → `[a, b, c, d]`; every other 16-byte address unchanged.
    static func unwrappingIPv4Mapped(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count == 16,
              bytes[0..<10].allSatisfy({ $0 == 0 }),
              bytes[10] == 0xff, bytes[11] == 0xff
        else { return bytes }
        return Array(bytes[12..<16])
    }

    static func sameAddress(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = addressBytes(lhs), let right = addressBytes(rhs) else { return false }
        return left == right
    }
}

/// Reads a process's established TCP sockets out of the kernel.
///
/// `proc_pidinfo(PROC_PIDLISTFDS)` then `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`
/// per descriptor: same-uid, no privileges, no entitlement, no network access.
/// It is the same class of read the rest of this subsystem already does
/// (`KERN_PROC_ALL`, `KERN_PROCARGS2`, `proc_pidpath`) — kernel facts about our
/// own user's processes, which nothing in userspace gets to write.
///
/// Every failure returns nil, which callers must treat as "unreadable", never
/// as "no sockets": an empty list is a positive claim and a failed syscall is
/// not one.
enum SSHProcessSocketReader {
    /// Hard ceiling on descriptors examined for one process. An ssh client has
    /// a handful; a runaway or hostile fd table must not turn a dictation into
    /// a syscall storm.
    static let maxDescriptors = 512

    /// `tcp_sockinfo.tcpsi_state` for ESTABLISHED, from `<netinet/tcp_fsm.h>`'s
    /// `TSI_S_ESTABLISHED`. Only established sockets are a connection anyone is
    /// looking at: a half-open or listening socket (an `ssh -L` bind) has no
    /// peer to match against.
    static let tcpStateEstablished: Int32 = 1

    static let live: @Sendable (Int32) -> [SSHClientSocket]? = { pid in
        establishedTCPSockets(pid: pid)
    }

    static func establishedTCPSockets(pid: Int32) -> [SSHClientSocket]? {
        guard let descriptors = descriptors(pid: pid) else { return nil }
        var sockets: [SSHClientSocket] = []
        for descriptor in descriptors.prefix(maxDescriptors)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            guard let socket = socket(pid: pid, descriptor: descriptor.proc_fd) else { continue }
            sockets.append(socket)
        }
        return sockets
    }

    private static func descriptors(pid: Int32) -> [proc_fdinfo]? {
        let sizeInBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sizeInBytes > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Headroom: descriptors can open between the sizing call and the fetch.
        let capacity = Int(sizeInBytes) / stride + 16
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let fetched = buffer.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard fetched > 0 else { return nil }
        return Array(buffer.prefix(Int(fetched) / stride))
    }

    private static func socket(pid: Int32, descriptor: Int32) -> SSHClientSocket? {
        var info = socket_fdinfo()
        // `stride` for the buffer we offer (never smaller than C's `sizeof`,
        // which is what the kernel demands), `size` for what must have been
        // filled: Swift may report a struct as smaller than its stride, and
        // demanding equality against either alone is a portability trap.
        let read = proc_pidfdinfo(
            pid, descriptor, PROC_PIDFDSOCKETINFO, &info,
            Int32(MemoryLayout<socket_fdinfo>.stride)
        )
        // A descriptor can close under us; a short read means the layout was
        // not what we think it is. Both skip this fd rather than guess.
        guard read >= Int32(MemoryLayout<socket_fdinfo>.size) else { return nil }
        guard info.psi.soi_kind == SOCKINFO_TCP else { return nil }
        let tcp = info.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == tcpStateEstablished else { return nil }
        let inner = tcp.tcpsi_ini
        // Ports live in the kernel in NETWORK byte order, widened into an
        // `int`. `lsof` does the same conversion; skipping it silently swaps
        // every port's bytes and the join would never match.
        let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: inner.insi_lport))
        let peerPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: inner.insi_fport))
        guard localPort > 0, peerPort > 0 else { return nil }
        guard let peerAddress = foreignAddressText(inner) else { return nil }
        return SSHClientSocket(
            localPort: localPort, peerPort: peerPort, peerAddress: peerAddress
        )
    }

    /// The foreign address as text. `insi_vflag` says which member of the
    /// union is live; anything else is a socket we decline to describe.
    private static func foreignAddressText(_ info: in_sockinfo) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if info.insi_vflag & UInt8(INI_IPV4) != 0 {
            var address = info.insi_faddr.ina_46.i46a_addr4
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil
            else { return nil }
        } else if info.insi_vflag & UInt8(INI_IPV6) != 0 {
            var address = info.insi_faddr.ina_6
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil
            else { return nil }
        } else {
            return nil
        }
        // Bounded decode, matching `TTYProcessTable`'s: stop at the NUL rather
        // than trusting one to be there.
        let text = String(
            decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return text.isEmpty ? nil : text
    }
}
#endif
