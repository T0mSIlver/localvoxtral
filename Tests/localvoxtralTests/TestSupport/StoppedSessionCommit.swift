import XCTest
@testable import localvoxtral

/// Returns when the stop-commit has actually finished, by awaiting the
/// commit's own task.
///
/// Call it directly after `finishStoppedSession`, with no suspension in
/// between: the task is read while the value that call just stored is
/// still there, and the task clears it on its own way out. A stop that
/// commits synchronously (nothing to polish) leaves it nil and is already
/// over by the time it returns.
///
/// The deadline poll this replaces returned whichever way it went, so a
/// loaded runner asserted on a session still in flight — a wrong value on
/// a rerun-green test (#392/#395/#398).
@MainActor
func awaitStoppedSessionCommit(
    _ viewModel: DictationViewModel,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let commitTask = viewModel.session.polishAndCommitTask
    await commitTask?.value
    XCTAssertFalse(
        viewModel.session.isCompletingStoppedSession,
        "the commit must be over before anything reads what it wrote",
        file: file,
        line: line
    )
}
