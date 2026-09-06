import ClaudeContextWire
import Foundation
import XCTest
@testable import localvoxtral

#if canImport(Darwin)
import Darwin

/// Can the reader describe ANOTHER process's established socket?
///
/// This is the only question that matters for the plain-ssh join, and the
/// existing `SSHProcessSocketReaderTests` never asked it: every assertion there
/// reads `getpid()`. A reader that works only on its own process passes all of
/// them and then reports "no established connection on this ssh" for every real
/// `ssh` on the machine — which is exactly what the owner's Mac reported for a
/// live plain-ssh session whose socket the server could see (field report,
/// 2026-09-06).
///
/// The fixture is a real child holding a real connection to a listener this
/// process owns, so "the child has an established socket" is a fact the test
/// establishes rather than assumes.
@MainActor
final class SSHProcessSocketReaderCrossProcessTests: XCTestCase {
    /// A listening loopback socket on an ephemeral port, and that port.
    private func makeListener() throws -> (descriptor: Int32, port: UInt16) {
        let raw = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        let listener = try XCTUnwrap(raw >= 0 ? raw : nil, "socket() failed: \(errno)")
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = Darwin.inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0, "bind failed: \(errno)")
        XCTAssertEqual(Darwin.listen(listener, 4), 0, "listen failed: \(errno)")
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listener, $0, &length)
            }
        }
        return (listener, UInt16(bigEndian: assigned.sin_port))
    }

    /// A live child process holding one established connection to `listener`,
    /// plus the accepted end and the child's source port.
    private struct ChildConnection {
        let process: Process
        let acceptedDescriptor: Int32
        let childPort: UInt16
        /// Kept alive so the child does not see EOF on stdin and exit.
        let standardInput: Pipe
    }

    /// `/usr/bin/nc` is on every macOS install and, with an open stdin, holds
    /// the connection until it is terminated.
    ///
    /// The wait for the connection is a bounded `poll(2)` on the listener, not
    /// a sleep: a live process either connects or it does not, and the deadline
    /// only bounds how long a dead fixture may look alive (the posture
    /// `HerdrLaneWait` documents for the same reason).
    private func connectFromAChild(to listener: Int32, port: UInt16) throws -> ChildConnection {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["127.0.0.1", String(port)]
        let standardInput = Pipe()
        process.standardInput = standardInput
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let ready = withUnsafeMutablePointer(to: &descriptor) { Darwin.poll($0, 1, 10_000) }
        XCTAssertGreaterThan(ready, 0, "the child never connected (poll: \(errno))")

        var peer = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let accepted = withUnsafeMutablePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(listener, $0, &length)
            }
        }
        XCTAssertGreaterThanOrEqual(accepted, 0, "accept failed: \(errno)")
        return ChildConnection(
            process: process,
            acceptedDescriptor: accepted,
            childPort: UInt16(bigEndian: peer.sin_port),
            standardInput: standardInput
        )
    }

    private func tearDown(_ child: ChildConnection) {
        Darwin.close(child.acceptedDescriptor)
        child.process.terminate()
        child.process.waitUntilExit()
    }

    func testTheReaderDescribesAnotherSameUserProcessesEstablishedSocket() throws {
        let (listener, listenPort) = try makeListener()
        defer { Darwin.close(listener) }
        let child = try connectFromAChild(to: listener, port: listenPort)
        defer { tearDown(child) }

        let sockets = try XCTUnwrap(
            SSHProcessSocketReader.establishedTCPSockets(pid: child.process.processIdentifier),
            "another same-user process's socket table must be readable — the join "
                + "reads the SURFACE's ssh, never its own process"
        )
        let match = sockets.first {
            $0.localPort == child.childPort && $0.peerPort == listenPort
        }
        let described = try XCTUnwrap(
            match,
            "the reader must find the connection the child holds "
                + "(client \(child.childPort) -> \(listenPort)); saw \(sockets)"
        )
        XCTAssertEqual(described.peerAddress, "127.0.0.1")
    }

    /// A GRANDCHILD: `nc` launched in the background by a `sh` we spawn, so the
    /// process whose sockets are read is not one this process created.
    ///
    /// The distinction is the whole point. macOS's `proc_info` security policy
    /// is not simply "same uid": a child a process spawned is not the same
    /// access class as an unrelated process of the same user, and the join
    /// reads `ssh` processes it never spawned. A test that only ever reads its
    /// own child can pass while the shipped reader sees nothing.
    private func connectFromAGrandchild(
        to listener: Int32, port: UInt16
    ) throws -> (shell: Process, grandchildPID: Int32, accepted: Int32, childPort: UInt16, stdin: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `sleep | nc` rather than a bare background `nc`: a POSIX shell gives a
        // background job /dev/null on stdin, so nc reads EOF, half-closes, and
        // the socket sits in FIN_WAIT_2 — which is not established and made the
        // first version of this fixture prove nothing (measured: `state=9`).
        // The pipe keeps nc's stdin open, and `$!` after a pipeline is the LAST
        // element's pid, i.e. nc's.
        process.arguments = [
            "-c", "sleep 600 | /usr/bin/nc 127.0.0.1 \(port) & echo $! >&2; wait",
        ]
        let standardInput = Pipe()
        let standardError = Pipe()
        process.standardInput = standardInput
        process.standardOutput = Pipe()
        process.standardError = standardError
        try process.run()

        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let ready = withUnsafeMutablePointer(to: &descriptor) { Darwin.poll($0, 1, 10_000) }
        XCTAssertGreaterThan(ready, 0, "the grandchild never connected (poll: \(errno))")

        var peer = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let accepted = withUnsafeMutablePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(listener, $0, &length)
            }
        }
        XCTAssertGreaterThanOrEqual(accepted, 0, "accept failed: \(errno)")

        // `sh` printed the background pid before waiting, and the connection
        // above proves it has started, so this read cannot block.
        //
        // `POSIXPipeRead`, not `FileHandle.availableData`: the latter is
        // BANNED repo-wide (AGENTS.md, PR #60) because a descriptor error
        // raises an uncatchable ObjC exception — here that would abort the
        // test runner and take the whole suite with it.
        let announced = POSIXPipeRead.nextChunk(
            fromDescriptor: standardError.fileHandleForReading.fileDescriptor
        )
        let text = String(decoding: announced, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let grandchildPID = try XCTUnwrap(Int32(text), "sh did not announce a pid: \(text)")
        return (process, grandchildPID, accepted, UInt16(bigEndian: peer.sin_port), standardInput)
    }

    func testTheReaderDescribesAProcessItDidNotSpawn() throws {
        let (listener, listenPort) = try makeListener()
        defer { Darwin.close(listener) }
        let held = try connectFromAGrandchild(to: listener, port: listenPort)
        defer {
            Darwin.close(held.accepted)
            kill(held.grandchildPID, SIGTERM)
            held.shell.terminate()
            held.shell.waitUntilExit()
        }

        let sockets = try XCTUnwrap(
            SSHProcessSocketReader.establishedTCPSockets(pid: held.grandchildPID),
            "a same-user process this one did NOT spawn must still be readable"
        )
        let match = sockets.first {
            $0.localPort == held.childPort && $0.peerPort == listenPort
        }
        XCTAssertNotNil(
            match,
            "the reader must find the connection a NON-child holds "
                + "(client \(held.childPort) -> \(listenPort)); saw \(sockets)"
        )
    }

}
#endif
