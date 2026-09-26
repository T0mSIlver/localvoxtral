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
