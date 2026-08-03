# Workflow Notes

## `ci.yml`

Every non-fast-path PR and push to main: build, advisory format lint (`.swift-format`;
flips to `--strict` after the one-shot tree reformat), unit tests with a
coverage summary (`llvm-cov report` over Sources — visibility for the PR
Proof section, not a gate), live STT-service integration tests, app packaging,
launch smoke test, an installable app artifact (`localvoxtral-app`, fetch
with `scripts/try-pr.sh`), and a `localvoxtral-dsym` artifact (30-day
retention) for symbolicating field crashes. Same-repo branches run on the
self-hosted Mac runner; fork PRs run on GitHub-hosted macOS.

Opt-in dogfood artifact: with the literal marker `[dogfood-package]` in the
PR body / head commit message, or a `workflow_dispatch` with `dogfood=true`,
the job packages a second, `LOCALVOXTRAL_DOGFOOD`-instrumented bundle after
the launch smoke and uploads it as `localvoxtral-app-dogfood` (7-day
retention) plus `localvoxtral-dsym-dogfood` (30-day — the instrumented
binary's UUID differs from the clean dSYM's). Fetch and launch it with
`scripts/try-pr.sh <pr|main> --dogfood`,
which also arms the runtime capture default. On manual dispatch the
conditional live-model lanes (polishd/speechd) skip — the dispatched ref's
own push/PR run already decided them.

The same `build-test` check takes a docs/scripts-only fast path when every
changed file passes `scripts/ci/docs-only-filter.sh`; it then skips all Swift,
helper, packaging, artifact, smoke, warm, and integration steps. The filter
fails open to the full run for unknown or ambiguous diffs and excludes CI
control files, packaging inputs (`assets/icons/**`), and every path selected
by the LLM/speechd lane filters; an explicit `[run-llm-eval]` /
`[run-speechd-integration]` marker also forces the full run.

## `release.yml`

One-command, gate-then-tag releases on the self-hosted runner:

```bash
./scripts/release.sh            # patch bump
./scripts/release.sh minor      # or major, or an explicit X.Y.Z
```

Pipeline: compute next version from the latest `v*` tag → release build →
unit tests → live integration tests (speechd STT service) → package app bundle → launch
smoke test → zip + dmg → **create tag** → publish GitHub release with
auto-generated notes and both artifacts.

The tag is created only after every gate passes, so a failed release leaves
no orphan tag. Releases are ad-hoc signed on purpose (a local signing cert
means nothing on users' machines); proper distribution signing needs a
Developer ID cert. Dispatch-only: pushing tags by hand no longer triggers a
release.

## `dmg-test.yml`

Manual-dispatch harness on the self-hosted Mac runner that packages the app,
builds the styled DMG, verifies it with `hdiutil`, and uploads it for eyeballing.

## `ui-smoke.yml`

Lock-aware evening AX smoke drill on the self-hosted Mac runner: three
scheduled slots (18:00/19:30/21:00 UTC, 20:00 Paris anchor), each gated by
`scripts/ci/ui-smoke-guard.sh` — a slot skips green when the Mac is on
battery power (scheduled lanes never drain the owner's MacBook,
`scripts/ci/ac-power-guard.sh`, shared with eval-e2e.yml's nightly), when
the screen is locked (the drill needs an unlocked GUI session), or when a
slot's drill already ran and passed that day, so at most one real drill runs
per day. Manual dispatch bypasses the guard.
Also runs on same-repo PRs when the `needs-ui-smoke` label is added — the
on-demand proof path for UI-affecting PRs (re-add the label to rerun after
new pushes; fork PRs never reach the self-hosted runner, label or no label).
It packages the app, launches a fresh menu bar instance, verifies the status
item, checks that launch alone does not spawn managed backend processes, opens
Settings from the status menu, selects the three settings tabs, checks the
managed backend rows, and verifies clean quit. Failure uploads
`ui-smoke-log`.

One-time runner TCC grants are required because the runner is a launchd agent
inside the owner's GUI session:

- Accessibility: allow the self-hosted runner process so System Events can
  drive the menu bar and settings window.
- Screen Recording: allow the self-hosted runner process so CoreGraphics
  preflight and screenshot capture can read window contents.

When either grant is missing, the smoke script fails immediately with an
actionable TCC message. Grant it once in System Settings > Privacy & Security,
then rerun the workflow.

## `capture-assets.yml`

Manual-dispatch screenshot refresh on the self-hosted Mac runner. It packages
the app and runs `scripts/capture-readme-assets.sh` when that script exists on
the selected ref, then uploads `assets/*.png` as the `readme-screenshots`
artifact. Before the screenshot script lands, the workflow intentionally
prints a clear skip message and exits successfully.

It needs the same one-time Accessibility and Screen Recording TCC grants as
`ui-smoke.yml`.
