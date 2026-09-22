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
because `mac-lanes` does them with the real signing identity. A same-repo
DRAFT therefore gets no bundle at all, unless its body carries `[mac-lanes]`.

**`mac-lanes` — the self-hosted Mac, same-repo PRs that are not drafts /
pushes to main / dispatches only.** A draft gets `build-test` alone; marking it
ready starts `mac-lanes`, and `[mac-lanes]` in a draft's body opts it in. One
Mac serves every agent, and work in progress was most of its queue (#418). Everything a hosted runner cannot supply: packaging and
launch-smoking the bundle signed with the stable `localvoxtral-dev` identity
(an ad-hoc signature would invalidate the owner's Accessibility grant on every
`scripts/try-pr.sh` install), the installable `localvoxtral-app` artifact and
`localvoxtral-dsym` (30-day retention) for symbolicating field crashes, the
live STT-service integration (path-gated on PRs by `scripts/ci/stt-lane-filter.sh`,
always on main), the conditional polishd/speechd/herdr live-model
lanes, the two MLX helper unit suites (kept here for the warm Cmlx build), the
dogfood capture suite and packaging, the UI-gate install, and the process leak
check. It keeps `clean: false` — the persistent warm `.build` that makes those
lanes affordable.

The two jobs run in parallel and share no artifact; each computes the
docs-only fast-path decision itself rather than serialising behind a `needs:`.

**Any step that launches the app on the self-hosted Mac must set
`LOCALVOXTRAL_DISABLE_LOGIN_KEYCHAIN: "1"`** (the launch smoke's
`LOCALVOXTRAL_SUPPRESS_STARTUP_PERMISSION_PROMPTS` already implies it). The app
carries no Team ID, so macOS keys each Keychain item to the code-signing hash of
the build that wrote it and a build CI just made never matches: the read raises
a modal Keychain dialog on the owner's desktop, once per run. Launching through
`open` needs `scripts/lib/launch-app.sh`'s `lv_open` — LaunchServices does not
pass the step's environment to the app.

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

`mac-lanes` is ordered in two phases: everything that produces an artifact
(packaging, uploads, launch smoke, the dogfood pass and the UI-gate install)
runs first, and the conditional live lanes (speechd/polishd/herdr) run after
it. A live lane's precondition must not cost a run the artifact it was
dispatched for — the herdr lane used to run before packaging, and while its
fixture still refused to start beside a herdr the account was running
(before #323), a `-f dogfood=true` dispatch on the owner's Mac never reached
the packaging steps at all (run 35084386041).

The live herdr lane is the one lane a dispatch still forces on (it needs no
weights, and dispatching it is how that external contract gets repeated).
`-f herdr=false` opts a single dispatch out, which is what
`scripts/try-pr.sh --dogfood` passes; pushes and PRs are unaffected and keep
the `scripts/ci/herdr-lane-filter.sh` path filter plus the
`[run-herdr-integration]` marker.

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
`[run-speechd-integration]` / `[run-herdr-integration]` /
`[run-stt-integration]` / `[dogfood-package]` / `[mac-lanes]` marker also
forces the full run.

The two helper unit suites are additionally path-gated per helper
(`scripts/ci/helper-lane-filter.sh`): a PR runs a helper's suite only when the
diff touches that helper's directory or the shared CI plumbing, while
dispatches and every push to main run both.

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

One-command, gate-then-tag releases on the self-hosted runner, in two
channels that share every gate:

```bash
./scripts/release.sh            # patch bump, stable channel
./scripts/release.sh minor      # or major, or an explicit X.Y.Z
./scripts/release.sh nightly    # a nightly prerelease of main, on demand
./scripts/release.sh rehearse [target] [ref]   # all gates, no tag, no release
```

Pipeline: compute next version from the latest `v*` tag → release build →
unit tests → live integration tests (speechd STT service) → package app bundle → launch
smoke test → zip + dmg → **create tag** → publish GitHub release with
auto-generated notes and both artifacts.

**Stable** is deliberate: dispatched by hand from `main` (or from a branch as
an `X.Y.Z-rc.N` prerelease), and it is what GitHub's `/releases/latest`
points at, which is what `install.sh` follows by default.

**Nightly** runs from the cron at 03:15 UTC (clear of eval-e2e at 04:45 and
the ui-smoke ladder at 18:00 to 21:00 on the same single runner), or on
demand with `release.sh nightly`. A schedule event is always the nightly
channel, and a real nightly publishes from `main` only. Its version is the
latest stable tag with the patch bumped and a `-nightly.YYYYMMDD` suffix,
with `.2`, `.3` and so on for a second build the same day
(`scripts/ci/nightly-version.sh`, tested by `test-nightly-version.sh`).
Nightlies publish with `prerelease: true`, so `/releases/latest` keeps
pointing at the newest stable release, and the stable bump base excludes
every `v*-*` tag so a nightly can never become the base for the next stable
version. Users opt in with `LOCALVOXTRAL_CHANNEL=nightly` (see
[docs/install.md](../../docs/install.md)).

Two things the nightly does that stable does not:

- **Skip when nothing is new.** A scheduled run stops green, with a
  step-summary line, when `main` is already released as the newest nightly or
  the newest stable tag. It also stops green when the Mac is on battery power
  (`scripts/ci/ac-power-guard.sh`, the guard eval-e2e and ui-smoke share). A
  dispatch always builds.
- **Prune.** After publishing, nightly releases beyond the newest 7 are
  deleted with their tags. The selection is
  `scripts/ci/prune-nightly-releases.sh`: it takes tags on stdin, prints only
  tags matching the nightly shape exactly, and touches no network, so
  `test-prune-nightly-releases.sh` can hold it to the cases that matter (a
  stable or rc tag is invisible to it). The workflow re-checks the shape
  before each delete.

**Rehearsal** (`publish=false`, or `release.sh rehearse`) runs every gate and
the packaging, then uploads the zip, dmg and checksums as the
`localvoxtral-release-rehearsal` artifact with 7-day retention. No tag, no
release, and the step summary says so. Rehearsal is allowed from any ref on
either channel, which is how a change to this workflow is proved before it
merges.

The unit-test gate mirrors `ci.yml`'s tier-0 unit step skip for skip, under
the same supervisor. Two of those skips are load-bearing:
`HerdrIntegrationTests` starts a live herdr server and carries no `XCTSkip`
by design, and `AgentDictationE2EEvalTests` is the nightly eval lane. A
release gate must not start either by accident.

Release notes: GitHub's generated PR list is always included, and a release
may additionally ship a **hand-written summary** committed ahead of time at
`docs/release-notes/<tag>.md` (e.g. `docs/release-notes/v0.9.0.md`, using the
exact tag release.yml computes). When that file exists it becomes the top of
the release body and the generated changelog is appended below it;
`scripts/ci/resolve-release-notes.sh` decides, and its self-test runs in CI's
shell-test step. The file is optional — with none, the release publishes with
generated notes exactly as before — but a file that exists and is empty is a
hard failure rather than a release with a blank human section. A nightly body
also opens with a fixed header saying which commit it is, how to install it,
and that it is not a stable release; a hand-written nightly file lands under
that header.

The tag is created only after every gate passes, so a failed release leaves
no orphan tag. Releases are ad-hoc signed on purpose (a local signing cert
means nothing on users' machines); proper distribution signing needs a
Developer ID cert. Dispatch-only: pushing tags by hand no longer triggers a
release.

## `cask.yml`

Pins the Homebrew tap,
[T0mSIlver/homebrew-localvoxtral](https://github.com/T0mSIlver/homebrew-localvoxtral),
to a stable release. `release.yml` calls it once a stable release is public;
nightlies and rc builds never reach it, because `brew upgrade` follows the tap.
It runs on a GitHub-hosted Mac, which has never had the app. In order: it
requires a published stable release, hashes the published zip and checks it
against the `.sha256` asset, renders the cask with `scripts/ci/render-cask.sh`,
installs and zaps that cask from a throwaway local tap
(`scripts/ci/verify-cask-install.sh`), pushes it with the
`HOMEBREW_TAP_DEPLOY_KEY` secret (a write deploy key on the tap), and installs
once more from the public tap. It refuses to move the tap to an older version.

The cask's text lives in the renderer, not in the tap: edit it there, and the
next release or dispatch carries it over. A run that goes red before the push
leaves a good release and a tap on the previous version. Repair it with:

```bash
gh workflow run cask.yml -f tag=v0.9.0
```

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

The same job then repackages the app as a dogfood build and runs
`scripts/e2e-dictation.sh`: the packaged app dictates from a WAV in place of
the microphone into a throwaway target window, once per scenario in
`scripts/e2e/scenarios/`, and the inserted text is scored against the spoken
phrase. Both checks run even when the other failed. The script exits 3 when
the Mac could not run it (locked, no STT server, no Accessibility grant), which
a scheduled slot reports as a warning and a dispatch or label reports as a
failure. `e2e-dictation-log` is uploaded on every run. The guard answers
"already covered today" separately for the drill and for the dictation, so a
red drill neither hides a missing dictation nor makes all three slots repeat
one that passed.

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

## `codeql.yml`

Code scanning of the workflows themselves, on Ubuntu, on every push to main,
every same-repo PR that changes `.github/workflows/**` or
`.github/actions/**`, and Mondays at 06:23 UTC. The repo is public,
`mac-lanes` runs on the owner's machine with the signing identity and the
login keychain, and `release.yml` holds the token that publishes the DMG, so
an injectable `${{ }}` expression or an over-scoped `permissions:` block is
the failure worth catching. A fork PR is skipped: its token cannot write
security events, so the upload would fail. Workflow changes from a fork are
analysed by the push run once merged.

Swift is not analysed. On `macos-latest` the traced `swift build` of the root
package, about 3 minutes untraced, ran past a 45-minute limit and GitHub kept
no log (#470). Retrying it belongs on a hosted runner too: never move code
scanning to `[self-hosted, macOS, ARM64]`, the one Mac every agent queues
behind (#418).

## Action pins

Every `uses:` names a 40-character commit SHA with the tag in a trailing
comment (`@<sha> # v4.4.0`). A tag is mutable, and an action step on
`mac-lanes` runs on the owner's Mac with the signing identity, the login
keychain and the tier-2 TCC grants — in `release.yml`, next to the token that
publishes the DMG. `WorkflowActionPinningTests` (tier 0) fails on any ref that
is not a SHA, so a new lane must resolve one:

```bash
git ls-remote https://github.com/actions/checkout \
  'refs/tags/v4' 'refs/tags/v4^{}' | tail -1 | cut -f1
```

Not `gh api …/git/ref/tags/<tag>`: on an ANNOTATED tag that returns the tag
object's SHA, which is 40 hex characters the pin test accepts and Actions then
refuses at run time, because it is not a commit. `ls-remote` prints the peeled
`^{}` ref last when there is one, so the line above yields the commit for
either kind of tag.

`.github/dependabot.yml` bumps them monthly, grouped into a single PR.
