# Contributing to localvoxtral

Thanks for considering a contribution. This is a small, fast-moving project
with daily users, so the bar is proof, not promise.

## Building and testing

You need a Mac with Apple Silicon and macOS 15+ — see
[docs/building.md](docs/building.md). `swift build` / `swift test` cover the
app package; `./scripts/package_app.sh release` builds the full bundle
including the MLX helpers. Working from a non-Mac machine is supported via an
SSH build host — the workflow and the full test-tier matrix are documented in
[AGENTS.md](AGENTS.md) and [docs/agent/test-tiers.md](docs/agent/test-tiers.md).

## Proof culture

Nothing ships on "it compiles":

- Every PR fills in the **Proof** section of the PR template with real
  command output — name the test that demonstrates the new or fixed
  behavior; "CI is green" alone is not proof for a behavior change.
- Bug fixes add a regression test, shown failing before the fix and passing
  after (both runs in the PR body).
- Never weaken a test to get green — no lowered thresholds, deleted
  assertions, skips, or widened tolerances. If a test blocks you, it is
  telling you something.
- UI-affecting changes state exactly what was verified by hand and how.
- Changes to prompts, model pins, or anything that alters what reaches the
  polishing model must run the LLM eval lanes — the trigger rules are in
  [docs/agent/test-tiers.md](docs/agent/test-tiers.md).

## Working with AI agents

If you develop with an AI coding agent, the repo ships an
[AGENTS.md](AGENTS.md) (with `CLAUDE.md` importing it) that most agents read
automatically, plus deep guides under [docs/agent/](docs/agent/) and
colocated `AGENTS.md` files next to sensitive subtrees. Agent-assisted PRs
are welcome; they meet the same proof bar, and you are responsible for
reviewing what you submit.

## Ground rules

- Fork PRs run on GitHub-hosted CI (the self-hosted Mac runner is a personal
  machine); some live-inference lanes self-skip there — say so in the Proof
  section rather than leaving it blank.
- Security-sensitive areas (the Claude Code context path, remote enrollment,
  session joins) have documented invariants in
  [docs/agent/invariants.md](docs/agent/invariants.md) — read them before
  proposing changes there; deliberate tradeoffs are not bugs.
- Questions or ideas: open an issue before a large PR.
