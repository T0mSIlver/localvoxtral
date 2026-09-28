# Learned-term over-application eval

`over-application.json` holds dictations over one learned term each. In the
`ordinary` cases the term's words are meant as ordinary words ("we should use
auth tokens" with `useAuth` learned); in the `term` cases, over the same
terms, the identifier is meant. The cases are written by hand, not taken from
anyone's dictations.

`LearnedTermOverApplicationEvalTests` (localvoxtralCore, runs on Linux) scores
what the matcher pre-applies before polish, with and without
`RepoVocabularyMatcher.withholdingOrdinaryReadings`, and prints one line per
arm:

```bash
./scripts/core-tests-linux.sh --filter LearnedTermOverApplicationEvalTests
```

It also checks term recall on the file-name and repo-vocabulary strata of
`../agent-dictation`, with each case's required tokens as the learned terms,
so the guard cannot buy precision there. The counts are pinned in the test: a
change that moves one updates the pin and quotes both lines in its PR.

Only pre-application is scored. A withheld term is offered to the polish
model, and whether the model then applies it where it belongs is not
measured here.

# Project-terms proposals

`project-term-proposals.json` holds what Claude Code and Vibe proposed as the
terms of ten public repositories (#914): the owner's public repositories and
three well-known ones. Each agent answered twice, once with the prompt before
#914, which asked for the code's names, and once with the one after it, which
asks for names people say. A blind judge (GLM 5.3, never told which prompt or
agent proposed a term) labeled every term `say` or `no`: would a builder who
talks to coding agents and does not read the code say it aloud?

`ProjectTermProposalEvalTests` (localvoxtralCore, runs on Linux) prints, per
agent and prompt, the share of proposed terms labeled `say`, before and after
`ProjectTermProposal.acceptedTerms` filters the answer. It also pins the terms
labeled `say` that the filter drops:

```bash
./scripts/core-tests-linux.sh --filter ProjectTermProposalEvalTests
```

The judge gets some names wrong: it labels `herdr` and `mlx-audio-swift`
`no`. The labels are kept as it gave them; the shares are a comparison
between prompts, not a precision figure. `scripts/linux/project-terms-eval.py`
rebuilds the file from live runs.
