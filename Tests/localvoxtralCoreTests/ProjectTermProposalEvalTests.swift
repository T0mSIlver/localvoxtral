import Foundation
import XCTest
@testable import localvoxtralCore

/// How many of an agent's proposed terms are names the dictating user would
/// say (#914), over frozen answers from public repositories:
/// `EvalCorpus/learned-terms/project-term-proposals.json`. Each repository
/// holds Claude Code's and Vibe's answers to the old prompt and to the new
/// one, and every proposed term labeled `say` or `no` by a blind judge.
///
/// Deterministic, so the counts are pinned exactly: a filter change that
/// moves one moves the pin, in the same PR, with the scoreboard in its Proof.
final class ProjectTermProposalEvalTests: XCTestCase {
    private struct Corpus: Decodable {
        let repos: [Repo]
    }

    private struct Repo: Decodable {
        let repo: String
        let answers: [String: [String]]
        let say: [String]
        let no: [String]
    }

    private struct Score: Equatable, CustomStringConvertible {
        var proposed = 0
        var said = 0
        var kept = 0
        var keptSaid = 0

        var description: String {
            func share(_ part: Int, _ whole: Int) -> String {
                "\(part)/\(whole) (\(whole == 0 ? 0 : (100 * part + whole / 2) / whole)%)"
            }
            return "answer \(share(said, proposed)) said, filtered \(share(keptSaid, kept)) said"
        }
    }

    private static let arms = ["claude-old", "claude-new", "vibe-old", "vibe-new"]

    private func corpus() throws -> Corpus {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(
            Corpus.self,
            from: Data(contentsOf: root.appendingPathComponent("EvalCorpus/learned-terms/project-term-proposals.json"))
        )
    }

    func testTheCorpusIsLabeledCompletely() throws {
        for repo in try corpus().repos {
            let labeled = Set(repo.say).union(repo.no)
            XCTAssertTrue(Set(repo.say).isDisjoint(with: repo.no), repo.repo)
            for (arm, terms) in repo.answers {
                XCTAssertEqual(Set(terms).subtracting(labeled), [], "\(repo.repo) \(arm)")
            }
        }
    }

    func testTheShareOfTermsSaidAloud() throws {
        let repos = try corpus().repos
        var scores: [String: Score] = [:]
        for arm in Self.arms {
            var score = Score()
            for repo in repos {
                let terms = repo.answers[arm] ?? []
                let said = Set(repo.say)
                let kept = ProjectTermProposal.acceptedTerms(terms)
                score.proposed += terms.count
                score.said += terms.filter(said.contains).count
                score.kept += kept.count
                score.keptSaid += kept.filter(said.contains).count
            }
            scores[arm] = score
            print("project terms \(arm): \(score)")
        }
        XCTAssertEqual(scores["claude-old"], Score(proposed: 385, said: 142, kept: 179, keptSaid: 131))
        XCTAssertEqual(scores["claude-new"], Score(proposed: 341, said: 309, kept: 325, keptSaid: 306))
        XCTAssertEqual(scores["vibe-old"], Score(proposed: 391, said: 130, kept: 183, keptSaid: 120))
        XCTAssertEqual(scores["vibe-new"], Score(proposed: 353, said: 343, kept: 351, keptSaid: 341))
    }

    /// Every term the judge says someone would say, that the filter drops
    /// anyway. Pinned so a filter change that loses a name shows here. These
    /// are kept out on purpose: dotted command names, a Python module, an
    /// `org/name` id whose bare name is proposed too, and snake_case
    /// parameters, which the owner ruled identifiers (#914).
    func testTheNamesTheFilterDrops() throws {
        var dropped: [String] = []
        for repo in try corpus().repos {
            for term in repo.say where ProjectTermProposal.acceptedTerms([term]).isEmpty {
                dropped.append(term)
            }
        }
        print("project terms: the filter drops \(dropped.count) terms judged said: \(dropped)")
        XCTAssertEqual(dropped, [
            "hither.doctor", "hither.open", "hither.setup", "mlx_audio", "@huggingface/tokenizers",
            "Qwen/Qwen3.8-27B", "sentence-transformers/all-MiniLM-L6-v2", "max_model_len", "max_num_batched_tokens",
            "max_num_seqs", "subagent_prefix_tokens", "weight_dtype",
        ])
    }
}
