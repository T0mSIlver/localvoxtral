# agent-dictation eval corpus — agent notes

The corpus layout, case/stratum schemas, authoring rules, human-recording
operator guide, and the NON-NEGOTIABLE owner eval policy are all in
`README.md` here — read it before editing anything in this directory.

- Corpus or scorer changes are LLM-lane-relevant: run the lanes and paste the
  scoreboard per `../../docs/agent/test-tiers.md`.
- Never weaken a case or threshold to get green (proof culture, `AGENTS.md`
  at the repo root). Promoting a case to `required` needs cross-server-state
  evidence (restarts / prompt-cache configurations) in the promotion PR.
- Human WAV sets under `EvalRecordings/` are private and gitignored; recording
  and ablation workflows are documented in `../../docs/agent/test-tiers.md`
  ("Human agent-eval recordings and ablations").
