import Darwin
import Foundation
import Synchronization
import XCTest

@testable import localvoxtral

final class LegacyVoxmlxPortDefenseTests: XCTestCase {
    func testTerminatesOnlyListenerInsideLegacyVoxmlxToolTree() async {
        let root = URL(fileURLWithPath: "/tmp/localvoxtral-owned/backends", isDirectory: true)
        let occupant = ListeningProcess(
            pid: 123,
            executableURL: root.appendingPathComponent("tools/voxmlx/bin/python3.12")
        )
        let terminated = Mutex<[pid_t]>([])
        let defense = LegacyVoxmlxPortDefense(
            layout: BackendInstallLayout(root: root),
            occupantProbe: { _ in occupant },
            terminate: { pid in
                terminated.withLock { $0.append(pid) }
                return true
            }
        )

        let outcome = await defense.clearLegacyOccupantIfNeeded(port: 8471)
        XCTAssertEqual(outcome, .terminatedLegacy(occupant))
        XCTAssertEqual(terminated.withLock { $0 }, [123])
    }

    func testLeavesUnownedListenerAlone() async {
        let root = URL(fileURLWithPath: "/tmp/localvoxtral-owned/backends", isDirectory: true)
        let occupant = ListeningProcess(
            pid: 456,
            executableURL: URL(fileURLWithPath: "/Applications/Other.app/Contents/MacOS/server")
        )
        let terminated = Mutex<[pid_t]>([])
        let defense = LegacyVoxmlxPortDefense(
            layout: BackendInstallLayout(root: root),
            occupantProbe: { _ in occupant },
            terminate: { pid in
                terminated.withLock { $0.append(pid) }
                return true
            }
        )

        let outcome = await defense.clearLegacyOccupantIfNeeded(port: 8471)
        XCTAssertEqual(outcome, .occupiedByOther(occupant))
        XCTAssertTrue(terminated.withLock { $0 }.isEmpty)
    }

    func testSimilarPrefixOutsideLegacyTreeIsNotOwned() {
        let root = URL(fileURLWithPath: "/tmp/localvoxtral-owned/backends", isDirectory: true)
        XCTAssertFalse(
            LegacyVoxmlxPortDefense.isProvablyLegacyVoxmlx(
                executableURL: root.appendingPathComponent("tools/voxmlx-copy/bin/python"),
                installRoot: root
            )
        )
        XCTAssertTrue(
            LegacyVoxmlxPortDefense.isProvablyLegacyVoxmlx(
                executableURL: root.appendingPathComponent("bin/voxmlx-serve"),
                installRoot: root
            )
        )
    }
}
