import Foundation
import LocalvoxtralCLICore
import XCTest

@testable import localvoxtral

/// The failure alert's Show Log: which lines a failure asks for, and what the
/// window holds once `log show` answers or fails (#1072).
@MainActor
final class FailureLogTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testTheWindowHoldsTheDetailsThenTheLinesAndCopiesBoth() async {
        let model = FailureLogModel(details: "NSURLErrorDomain -1001")
        let output = Data(#"{"timestamp":"2026-09-21 14:13:20.000000+0000","messageType":"Error","category":"Polishing","eventMessage":"timed out"}"#.utf8)
        let recorded = AskedArguments()
        await model.load(.polishing, now: now, timeZone: utc) { arguments in
            recorded.value = arguments
            return .success(output)
        }
        let asked = recorded.value
        XCTAssertEqual(asked.last, #"subsystem == "com.localvoxtral" AND category IN {"Polishing", "Backends"}"#)
        XCTAssertEqual(asked[asked.firstIndex(of: "--start")! + 1], "2026-09-21 13:58:20")
        XCTAssertEqual(model.lines, .loaded("2026-09-21 14:13:20 [Polishing] error: timed out\n"))
        XCTAssertEqual(model.copyText, "NSURLErrorDomain -1001\n\n2026-09-21 14:13:20 [Polishing] error: timed out\n")

        let unreadable = FailureLogModel(details: nil)
        await unreadable.load(.realtime, now: now, timeZone: utc) { _ in
            .failure(AgentCLILogsReadFailure("/usr/bin/log exited with 64"))
        }
        XCTAssertEqual(unreadable.lines, .unreadable("Could not read the log: /usr/bin/log exited with 64."))
    }

    func testTheWindowSkipsDetailsThatRepeatTheAlert() {
        XCTAssertNil(ModalConnectionFailurePresenter.windowDetails(message: "Timed out.", technicalDetails: " Timed out. "))
        XCTAssertNil(ModalConnectionFailurePresenter.windowDetails(message: "Timed out.", technicalDetails: nil))
        XCTAssertEqual(
            ModalConnectionFailurePresenter.windowDetails(message: "Timed out.", technicalDetails: "code -1001"), "code -1001")
    }
}

private final class AskedArguments: @unchecked Sendable {
    var value: [String] = []
}
