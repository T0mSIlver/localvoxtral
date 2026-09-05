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

Both lanes build with whatever Xcode toolchain is already on the machine —
no `Setup Swift` step. Fork PRs previously pinned a separate swift.org
toolchain (`swift-actions/setup-swift@v2`, `swift-version: "6.2"`), but its
6.2.1 resolution ships with assertions enabled and asserts compiling this
app's `@MainActor deinit`; Xcode's bundled toolchain doesn't have that
problem, so hosted runners now use it too, same as self-hosted. Neither
lane pins a version, so the hosted job records `xcodebuild -version` and
`swift --version` in its step summary and keys the SwiftPM cache on them —
when the image's default Xcode moves, the log says which build ran and no
`.build` tree crosses toolchains.

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

Forcing the hosted lane: `workflow_dispatch` with `hosted=true` runs
`build-test` for a same-repo ref on `macos-latest` instead of the Mac —

```bash
gh workflow run CI --ref <branch> -f hosted=true
```

That is the only way to exercise the fork-PR lane without a fork, and it is
also the switch for moving tier 0 off the personal Mac. Everything keyed on
`runner.environment == 'self-hosted'` skips exactly as it does for a fork PR:
the workspace process cleanup, all four lane-decide steps, the live STT /
polishd / speechd / herdr lanes, both helper unit suites, the dogfood capture
suite and packaging, the Metal-toolchain probe, and the process leak check.
What remains is the shell-test step, the installer test, format lint, the unit
suite, packaging (helpers skipped, ad-hoc signature), the artifacts, and the
launch smoke. The input can only move a job toward `macos-latest`; no input
value can pull a fork PR onto the self-hosted runner.

The same `build-test` check takes a docs/scripts-only fast path when every
changed file passes `scripts/ci/docs-only-filter.sh`; it then skips all Swift,
helper, packaging, artifact, smoke, warm, and integration steps. The filter
fails open to the full run for unknown or ambiguous diffs and excludes CI
control files, packaging inputs (`assets/icons/**`), and every path selected
by the LLM/speechd lane filters; an explicit `[run-llm-eval]` /
`[run-speechd-integration]` marker also forces the full run.

One tier-0 guard deliberately survives the fast path: `AGENTS.md` and the deep
guides are `*.md`, so a diff that touches only them is `docs_only=true` and the
Swift lane — including `AgentsGuideSizeTests`, whose entire job is guarding
`AGENTS.md`'s 32 KiB Codex truncation budget — used to be skipped exactly on
the diffs that can break it. `scripts/ci/test-agents-guide-budget.sh` is a
shell port of that test, run in the ungated shell-test step. It parses the cap,
the router targets and the anchors out of `AgentsGuideSizeTests.swift` rather
than restating them, and fails if that file grows an assertion it has not
ported — so the two cannot drift.

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

## `hosted-tcc-probe.yml`

Dispatch-only research probe on GitHub-**hosted** macOS (`macos-15` and
`macos-26` matrix), answering whether the UI tier could leave the owner's Mac.
It reports whether a hosted runner has a real GUI/WindowServer session, what
`csrutil status` says, which TCC rows the image ships (`actions/runner-images`
bakes Accessibility, Screen Recording, PostEvent and AppleEvents grants for
`/bin/bash` and `/usr/bin/osascript` into both databases at image-build time),
whether System Events UI scripting and `screencapture` actually work there, and
whether a microphone device exists at all. It then packages the app and runs
`ui-smoke.sh` for real.

The decisive step runs first: `AXIsProcessTrusted()` /
`CGPreflightScreenCaptureAccess()` under all three invocation shapes
(interpreted `swift file.swift` — what `ui-smoke.sh` uses today — compiled, and
`osascript`-spawned), printed adjacently, because TCC attributes a grant to the
*responsible* process and it is unresolved whether a `swift`-spawned child
inherits bash's.

Every probe step is `continue-on-error: true` on purpose: a red step is a
result, not a breakage. Only the hosted-only guard may fail the job — it aborts
unless `runner.environment == github-hosted`, so the probe can never touch the
owner's personal machine. Never add `self-hosted` to its matrix. Output lands in
the `hosted-tcc-probe-<image>` artifact, including a full-screen PNG (whether
the framebuffer is real is a question a screenshot answers better than a byte
count).

## `capture-assets.yml`

Manual-dispatch screenshot refresh on the self-hosted Mac runner. It packages
the app and runs `scripts/capture-readme-assets.sh` when that script exists on
the selected ref, then uploads `assets/*.png` as the `readme-screenshots`
artifact. Before the screenshot script lands, the workflow intentionally
prints a clear skip message and exits successfully.

It needs the same one-time Accessibility and Screen Recording TCC grants as
`ui-smoke.yml`.
