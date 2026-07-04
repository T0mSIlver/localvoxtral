# Workflow Notes

## `ci.yml`

Every PR and push to main: build, unit tests, live voxmlx integration tests,
app packaging, launch smoke test, and an installable app artifact
(`localvoxtral-app`, fetch with `scripts/try-pr.sh`). Same-repo branches run
on the self-hosted Mac runner; fork PRs run on GitHub-hosted macOS.

## `release.yml`

One-command, gate-then-tag releases on the self-hosted runner:

```bash
./scripts/release.sh            # patch bump
./scripts/release.sh minor      # or major, or an explicit X.Y.Z
```

Pipeline: compute next version from the latest `v*` tag → release build →
unit tests → live integration tests (voxmlx) → package app bundle → launch
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

Nightly and manual-dispatch AX smoke drill on the self-hosted Mac runner.
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

## `mlx-lm-test.yml`

Manual-dispatch harness that installs `mlx_lm.server` from any ref of the
T0mSIlver/mlx-lm fork on the self-hosted runner, serves the polishing model,
and probes chat/completions through the prompt-cache path. Used to verify
fork changes (MLX needs Apple Silicon).
