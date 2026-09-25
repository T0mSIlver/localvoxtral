import Foundation
import XCTest
@testable import localvoxtralCore

/// Over-application of learned terms as numbers (#522), at the stage the guard
/// changes: what the matcher pre-applies before polish. Deterministic, so the
/// counts are pinned exactly; a change that moves one moves the pin, in the
/// same PR, with the scoreboard in its Proof.
///
/// Two sets, each scored with and without the guard:
/// - `EvalCorpus/learned-terms/over-application.json`: dictations where the
///   learned term's ordinary words are meant, and dictations over the same
///   terms where the term is meant.
/// - Term recall on the existing corpus: every file-name and repo-vocabulary
///   case of `EvalCorpus/agent-dictation`, its required tokens taken as the
///   learned terms. The guard must not lose one there.
///
/// A withheld term is not lost to the dictation: it goes to the model as a
/// verification pair. The "offered" column counts those; whether the model
/// then applies it is the LLM lane's to measure.
final class LearnedTermOverApplicationEvalTests: XCTestCase {
    private struct CaseFile: Decodable {
        let cases: [Case]
    }

    private struct Case: Decodable {
        let id: String
        let learnedTerm: String
        let transcript: String
        let meant: String
    }

    private struct Stratum: Decodable {
        struct Case: Decodable {
            let spokenForm: String
            let requiredTokens: [String]
        }

        let cases: [Case]
    }

    private struct Result {
        var appliedWhereMeant = 0
        var offeredWhereMeant = 0
        var termCases = 0
        var keptWhereOrdinary = 0
        var ordinaryCases = 0
        var existingRecalled = 0
        var existingTokens = 0
        var misses: [String] = []
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func outcome(
        _ transcript: String,
        terms: [String],
        guarded: Bool
    ) -> RepoVocabularyMatcher.GroundingOutcome {
        let grounded = RepoVocabularyMatcher.groundedCandidates(
            transcript: transcript,
            vocabulary: RepoVocabulary(terms: terms, branch: nil)
        )
        return guarded
            ? RepoVocabularyMatcher.withholdingOrdinaryReadings(grounded, transcript: transcript)
            : grounded
    }

    private func score(guarded: Bool) throws -> Result {
        let evalSet = try JSONDecoder().decode(
            CaseFile.self,
            from: Data(contentsOf: Self.repoRoot.appendingPathComponent(
                "EvalCorpus/learned-terms/over-application.json"))
        )
        var result = Result()
        for item in evalSet.cases {
            let grounded = outcome(item.transcript, terms: [item.learnedTerm], guarded: guarded)
            let output = RepoVocabularyMatcher.preapplying(entries: grounded.entries, to: item.transcript)
            let applied = output.contains(item.learnedTerm)
            switch item.meant {
            case "term":
                result.termCases += 1
                if applied { result.appliedWhereMeant += 1 } else { result.misses.append(item.id) }
                if !applied, grounded.verificationCandidates.contains(where: {
                    $0.replaceWith == item.learnedTerm
                }) {
                    result.offeredWhereMeant += 1
                }
            case "ordinary":
                result.ordinaryCases += 1
                if !applied { result.keptWhereOrdinary += 1 } else { result.misses.append(item.id) }
            default:
                XCTFail("\(item.id): meant must be term or ordinary")
            }
        }

        for name in ["c-filenames.json", "i-repo-vocabulary.json"] {
            let stratum = try JSONDecoder().decode(
                Stratum.self,
                from: Data(contentsOf: Self.repoRoot.appendingPathComponent(
                    "EvalCorpus/agent-dictation/strata/\(name)"))
            )
            for item in stratum.cases {
                let grounded = outcome(item.spokenForm, terms: item.requiredTokens, guarded: guarded)
                let output = RepoVocabularyMatcher.preapplying(entries: grounded.entries, to: item.spokenForm)
                result.existingTokens += item.requiredTokens.count
                result.existingRecalled += item.requiredTokens.filter { output.contains($0) }.count
            }
        }
        return result
    }

    private func line(_ label: String, _ result: Result) -> String {
        "learned-terms eval \(label): ordinary kept \(result.keptWhereOrdinary)/\(result.ordinaryCases), "
            + "term applied \(result.appliedWhereMeant)/\(result.termCases) "
            + "(+\(result.offeredWhereMeant) offered to the model), "
            + "existing-set recall \(result.existingRecalled)/\(result.existingTokens); "
            + "missed: \(result.misses.isEmpty ? "none" : result.misses.joined(separator: " "))"
    }

    func testScoreboard() throws {
        let before = try score(guarded: false)
        let after = try score(guarded: true)
        print(line("before", before))
        print(line("after", after))

        XCTAssertEqual(before.ordinaryCases, 22)
        XCTAssertEqual(before.termCases, 20)
        XCTAssertEqual(after.existingRecalled, before.existingRecalled, "the guard lost a term on the existing set")
        XCTAssertEqual(before.keptWhereOrdinary, 0)
        XCTAssertEqual(before.appliedWhereMeant, 20)
        XCTAssertEqual(after.keptWhereOrdinary, 21)
        XCTAssertEqual(after.appliedWhereMeant, 16)
        XCTAssertEqual(after.appliedWhereMeant + after.offeredWhereMeant, after.termCases)
    }
}
