# Workflow Notes

## `ci.yml`

`ci.yml` runs **two jobs in parallel**, split by what actually needs the
owner's Mac (owner decision 2026-09-05):

**`build-test` — GitHub-hosted macOS (`macos-latest`), every event, every
contributor.** The required status check on main, and the portable half of CI:
the pure-shell gate/process-cleanup suites, the installer-resolution test,
advisory format lint (`.swift-format`; flips to `--strict` after the one-shot
tree reformat), the unit suite with a coverage summary (`llvm-cov report` over
Sources — visibility for the PR Proof section, not a gate), and the complete
unit-test log as an artifact. Same-repo PRs run here too, not just forks: the
single self-hosted runner was 89 % busy during a four-agent burst and 3.4 h of
work produced 8.95 h of queue, while a measured hosted run executed the
identical 2769 test cases in the same wall-clock with an 8 s queue — and
hosted runners are free for public repositories.

A **fork PR gets only this job** (`mac-lanes` never runs untrusted code on the
owner's machine), so on a fork it additionally packages, uploads and
launch-smokes an ad-hoc-signed bundle. Same-repo runs skip those steps here
because `mac-lanes` does them with the real signing identity.

**`mac-lanes` — the self-hosted Mac, same-repo PRs / pushes to main /
dispatches only.** Everything a hosted runner cannot supply: packaging and
launch-smoking the bundle signed with the stable `localvoxtral-dev` identity
(an ad-hoc signature would invalidate the owner's Accessibility grant on every
`scripts/try-pr.sh` install), the installable `localvoxtral-app` artifact and
`localvoxtral-dsym` (30-day retention) for symbolicating field crashes, the
live STT-service integration, the conditional polishd/speechd/herdr live-model
lanes, the two MLX helper unit suites (kept here for the warm Cmlx build), the
dogfood capture suite and packaging, the UI-gate install, and the process leak
check. It keeps `clean: false` — the persistent warm `.build` that makes those
lanes affordable.

The two jobs run in parallel and share no artifact; each computes the
docs-only fast-path decision itself rather than serialising behind a `needs:`.

Both lanes build with whatever Xcode toolchain is already on the machine —
no `Setup Swift` step. Fork PRs previously pinned a separate swift.org
toolchain (`swift-actions/setup-swift@v2`, `swift-version: "6.2"`), but its
6.2.1 resolution ships with assertions enabled and asserts compiling this
app's `@MainActor deinit`; Xcode's bundled toolchain doesn't have that
problem, so hosted runners now use it too, same as self-hosted. Neither
lane pins a version, so `build-test` records `xcodebuild -version` and
`swift --version` in its step summary and keys the SwiftPM cache on them —
when the image's default Xcode moves, the log says which build ran and no
`.build` tree crosses toolchains.

Opt-in dogfood artifact: with the literal marker `[dogfood-package]` in the
PR body / head commit message, or a `workflow_dispatch` with `dogfood=true`,
`mac-lanes` packages a second, `LOCALVOXTRAL_DOGFOOD`-instrumented bundle
after the launch smoke and uploads it as `localvoxtral-app-dogfood` (7-day
retention) plus `localvoxtral-dsym-dogfood` (30-day — the instrumented
binary's UUID differs from the clean dSYM's). Fetch and launch it with
`scripts/try-pr.sh <pr|main> --dogfood`,
which also arms the runtime capture default. On manual dispatch the
conditional live-model lanes (polishd/speechd) skip — the dispatched ref's
own push/PR run already decided them.

The `hosted` dispatch input is a **no-op** now: it existed to force
`build-test` onto a hosted runner, which is where it always runs. It is kept
for one release so a scripted `-f hosted=true` does not fail on an unknown
input, and cannot be repurposed to move `mac-lanes` — that job exists
precisely because its work needs that Mac.

The docs/scripts-only fast path applies to both jobs when every changed file
passes `scripts/ci/docs-only-filter.sh`; they then skip all Swift, helper,
packaging, artifact, smoke, warm, and integration steps. The filter fails open
to the full run for unknown or ambiguous diffs and excludes CI control files,
packaging inputs (`assets/icons/**`), and every path selected by the
LLM/speechd lane filters; an explicit `[run-llm-eval]` /
`[run-speechd-integration]` marker also forces the full run.

The two helper unit suites are additionally path-gated per helper
(`scripts/ci/helper-lane-filter.sh`): a PR runs a helper's suite only when the
diff touches that helper's directory or the shared CI plumbing, while
dispatches and every push to main run both.

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

Release notes: GitHub's generated PR list is always included, and a release
may additionally ship a **hand-written summary** committed ahead of time at
`docs/release-notes/<tag>.md` (e.g. `docs/release-notes/v0.9.0.md`, using the
exact tag release.yml computes). When that file exists it becomes the top of
the release body and the generated changelog is appended below it;
`scripts/ci/resolve-release-notes.sh` decides, and its self-test runs in CI's
shell-test step. The file is optional — with none, the release publishes with
generated notes exactly as before — but a file that exists and is empty is a
hard failure rather than a release with a blank human section.

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
