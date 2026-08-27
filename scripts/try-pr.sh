#!/usr/bin/env bash
set -euo pipefail

# Download the CI-built app for a PR (or main) and launch it, for fast manual
# testing of UI/behavior that automated tests can't cover. Runs on macOS; the
# artifact is the exact bundle CI built and smoke-tested for that revision.
#
# Usage:
#   ./scripts/try-pr.sh <pr-number>            # e.g. ./scripts/try-pr.sh 30
#   ./scripts/try-pr.sh main                   # latest green build of main
#   ./scripts/try-pr.sh main --dogfood         # instrumented dogfood build
#
# --dogfood fetches the LOCALVOXTRAL_DOGFOOD-instrumented artifact
# (localvoxtral-app-dogfood), verifies its Info.plist stamp, arms the runtime
# capture opt-in default, and launches it. The dogfood artifact is OPT-IN in
# CI ([dogfood-package] marker or a manual dispatch with dogfood=true), so if
# the target's run doesn't carry one, this script offers to trigger a build
# and shows the latest run that does have one.
#
# Requires: gh (authenticated). Artifacts exist for CI runs made after the
# artifact-upload step landed; use "gh run rerun <run-id>" on older PRs.

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script launches a macOS app bundle — run it on the Mac." >&2
  exit 1
fi

TARGET=""
DOGFOOD=0
for arg in "$@"; do
  case "$arg" in
    --dogfood) DOGFOOD=1 ;;
    -*)
      echo "unknown flag: $arg" >&2
      echo "usage: $0 <pr-number|main> [--dogfood]" >&2
      exit 1
      ;;
    *)
      if [[ -n "$TARGET" ]]; then
        echo "usage: $0 <pr-number|main> [--dogfood]" >&2
        exit 1
      fi
      TARGET="$arg"
      ;;
  esac
done
if [[ -z "$TARGET" ]]; then
  echo "usage: $0 <pr-number|main> [--dogfood]" >&2
  exit 1
fi

ARTIFACT="localvoxtral-app"
(( DOGFOOD )) && ARTIFACT="localvoxtral-app-dogfood"

# BRANCH is what a workflow_dispatch would target; empty when dispatch is
# impossible (cross-repo fork PRs have no branch in this repo to dispatch on).
BRANCH=""
if [[ "$TARGET" == "main" ]]; then
  BRANCH="main"
  RUN_ID="$(gh run list --workflow CI --branch main --status success --limit 1 \
    --json databaseId --jq '.[0].databaseId')"
else
  IFS=$'\t' read -r HEAD_SHA PR_BRANCH PR_CROSS_REPO < <(gh pr view "$TARGET" \
    --json headRefOid,headRefName,isCrossRepository \
    --jq '[.headRefOid, .headRefName, (.isCrossRepository|tostring)] | @tsv')
  [[ "$PR_CROSS_REPO" == "true" ]] || BRANCH="$PR_BRANCH"
  RUN_ID="$(gh run list --workflow CI --commit "$HEAD_SHA" --status success --limit 1 \
    --json databaseId --jq '.[0].databaseId')"
fi

if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
  echo "No successful CI run found for '$TARGET' with a downloadable build." >&2
  echo "If the PR predates artifact uploads, re-run its checks: gh pr checks $TARGET / gh run rerun" >&2
  exit 1
fi

run_has_artifact() {
  # Capture first, grep second: `gh | grep -q` under pipefail can turn an
  # early grep exit into a spurious SIGPIPE "failure", and a gh error must
  # abort loudly rather than read as "artifact missing".
  local names
  # Expired artifacts keep their listing row but download as 410 Gone, so
  # they must not count as present.
  if ! names="$(gh api "repos/{owner}/{repo}/actions/runs/$1/artifacts" \
      --jq '.artifacts[] | select(.expired | not) | .name')"; then
    echo "Failed to list artifacts for run $1 (gh api error)." >&2
    exit 1
  fi
  grep -qxF "$ARTIFACT" <<<"$names"
}

if (( DOGFOOD )) && ! run_has_artifact "$RUN_ID"; then
  echo "No dogfood artifact on CI run $RUN_ID for '$TARGET' — the dogfood lane is opt-in"
  echo "([dogfood-package] in the PR body / head commit message, or a manual dispatch)."
  echo

  # Newest non-expired dogfood artifact anywhere in the repo, so there is
  # always a concrete "latest build that HAS one" to point at (or use).
  # sort_by(.created_at) because the REST endpoint documents no response
  # ordering; 7-day retention keeps the population well inside one page.
  LATEST="$(gh api "repos/{owner}/{repo}/actions/artifacts?name=localvoxtral-app-dogfood&per_page=100" \
    --jq '[.artifacts[] | select(.expired | not)] | sort_by(.created_at) | last
          | if . == null then ""
            else "\(.workflow_run.id)\t\(.workflow_run.head_branch)\t\(.workflow_run.head_sha[0:7])\t\(.created_at)"
            end')"
  LATEST_RUN=""
  if [[ -n "$LATEST" ]]; then
    IFS=$'\t' read -r LATEST_RUN LATEST_BRANCH LATEST_SHA LATEST_DATE <<<"$LATEST"
    echo "Latest existing dogfood build: $LATEST_BRANCH @ $LATEST_SHA (run $LATEST_RUN, created $LATEST_DATE)"
  else
    echo "No dogfood artifact exists anywhere yet (or all have expired — 7-day retention)."
  fi

  if [[ ! -t 0 ]]; then
    echo >&2
    echo "stdin is not a TTY — rerun interactively, or trigger a build yourself:" >&2
    if [[ -n "$BRANCH" ]]; then
      echo "  gh workflow run CI --ref $BRANCH -f dogfood=true" >&2
    else
      echo "  (cross-repo fork PR: fork PRs run on GitHub-hosted runners and never build" >&2
      echo "   dogfood artifacts — push the branch to this repo instead)" >&2
    fi
    exit 1
  fi

  echo
  [[ -n "$BRANCH" ]] && echo "  [t] trigger a fresh dogfood CI build of '$TARGET' and wait for it"
  [[ -n "$LATEST_RUN" ]] && echo "  [l] use that latest existing dogfood build instead"
  echo "  [q] quit"
  read -r -p "Choice: " CHOICE
  case "$CHOICE" in
    t|T)
      if [[ -z "$BRANCH" ]]; then
        echo "Can't dispatch for a cross-repo fork PR — and fork PRs run on GitHub-hosted" >&2
        echo "runners, which never build dogfood artifacts (the lane is self-hosted-only)." >&2
        echo "Push the branch to this repo instead." >&2
        exit 1
      fi
      # gh workflow run doesn't return the run id; detect the new run by
      # comparing against the newest dispatch run that existed beforehand.
      PREV_DISPATCH="$(gh run list --workflow CI --event workflow_dispatch --branch "$BRANCH" \
        --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
      gh workflow run CI --ref "$BRANCH" -f dogfood=true
      echo "Dispatched. Waiting for the run to register..."
      NEW_RUN=""
      for _ in $(seq 1 24); do
        sleep 5
        CAND="$(gh run list --workflow CI --event workflow_dispatch --branch "$BRANCH" \
          --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
        if [[ -n "$CAND" && "$CAND" != "$PREV_DISPATCH" ]]; then
          NEW_RUN="$CAND"
          break
        fi
      done
      if [[ -z "$NEW_RUN" ]]; then
        echo "Dispatched run never appeared — check: gh run list --workflow CI --event workflow_dispatch" >&2
        exit 1
      fi
      echo "Watching run $NEW_RUN (full CI + dogfood packaging; ~a few minutes on a warm runner)..."
      if ! gh run watch "$NEW_RUN" --exit-status; then
        echo "CI run failed — see: gh run view $NEW_RUN" >&2
        exit 1
      fi
      # The newest-dispatch heuristic above can pick up someone else's
      # concurrent dispatch (possibly without dogfood=true); verify the
      # watched run actually produced the artifact before downloading.
      if ! run_has_artifact "$NEW_RUN"; then
        echo "Run $NEW_RUN finished green but has no dogfood artifact — a concurrent" >&2
        echo "dispatch may have been picked up instead of ours. Rerun this script." >&2
        exit 1
      fi
      RUN_ID="$NEW_RUN"
      ;;
    l|L)
      if [[ -z "$LATEST_RUN" ]]; then
        echo "No existing dogfood build to use." >&2
        exit 1
      fi
      RUN_ID="$LATEST_RUN"
      ;;
    *)
      exit 0
      ;;
  esac
fi

DEST="$(mktemp -d /tmp/localvoxtral-try.XXXXXX)"
gh run download "$RUN_ID" -n "$ARTIFACT" -D "$DEST"
ditto -x -k "$DEST/${ARTIFACT}.zip" "$DEST/extracted"
APP="$DEST/extracted/localvoxtral.app"
xattr -cr "$APP" 2>/dev/null || true

# Which binary is this? The Info.plist stamp is the ground truth (docs/agent/field-debugging.md:
# "confirm WHICH binary the user is actually running" has cost an hour once).
STAMP="$(/usr/libexec/PlistBuddy -c 'Print :LVXDogfoodCapture' "$APP/Contents/Info.plist" 2>/dev/null || echo absent)"
echo "Dogfood capture stamp: $STAMP"
if (( DOGFOOD )) && [[ "$STAMP" != "true" ]]; then
  echo "FATAL: --dogfood requested but the downloaded bundle is not stamped (LVXDogfoodCapture: $STAMP)." >&2
  echo "Refusing to launch a build that can't capture — this is exactly the wrong-binary confusion." >&2
  exit 1
fi
if (( ! DOGFOOD )) && [[ "$STAMP" != "absent" ]]; then
  echo "WARNING: this 'clean' artifact is stamped LVXDogfoodCapture=$STAMP — it can capture if armed."
fi

# Detect whether the downloaded bundle is ad-hoc. The reliable marker is the
# 'Signature=adhoc' line — and it MUST be read at -dvv (verbose>=2): at -dv the
# Authority/Signature detail lines are not printed at all, so grepping -dv for
# '^Authority=' ALWAYS misses and misreports every build as ad-hoc. That was the
# f7d248e regression: it re-signed even correctly identity-signed CI artifacts
# ad-hoc on every launch, giving each a fresh designated requirement and
# invalidating the app's Accessibility (TCC) grant each time (the "re-add it in
# System Settings after every try-pr" symptom).
if codesign -dvv "$APP" 2>&1 | grep -q '^Signature=adhoc'; then
  IS_ADHOC=1
  SIGNER="ad-hoc"
else
  IS_ADHOC=0
  SIGNER="$(codesign -dvv "$APP" 2>&1 | grep -m1 '^Authority=' | sed 's/^Authority=//' || echo 'identity')"
fi
if (( IS_ADHOC )); then
  # macOS 26 stalls the first launch of downloaded ad-hoc bundles forever at
  # _dyld_start (Gatekeeper first-exec scan); a LOCAL ad-hoc re-sign is the
  # field-proven fix. Only ad-hoc artifacts are re-signed, so an identity-signed
  # build keeps its stable signature — and its TCC grant — untouched.
  codesign --force --deep --sign - "$APP"
fi

if pgrep -x localvoxtral >/dev/null 2>&1; then
  echo "NOTE: another localvoxtral instance is running — quit it first to avoid"
  echo "      two menu bar icons / hotkey conflicts."
fi

if (( DOGFOOD )); then
  # Arm the runtime opt-in BEFORE launch so the first session already
  # captures. Same bundle id as the clean build, so this is the app's normal
  # defaults domain — and harmless to leave armed: release binaries don't
  # contain the capture code at all (compile gate), so a later clean try-pr
  # ignores the key.
  defaults write com.localvoxtral.app debug.dogfood_capture_enabled -bool true
  echo "Dogfood capture ARMED (debug.dogfood_capture_enabled = true)."
  echo "  records: ~/Library/Application Support/localvoxtral/dogfood"
  echo "  disarm:  defaults write com.localvoxtral.app debug.dogfood_capture_enabled -bool false"
fi

LAUNCH_LABEL="$SIGNER"
(( DOGFOOD )) && LAUNCH_LABEL="$LAUNCH_LABEL, dogfood"
echo "Launching build of '$TARGET' (CI run $RUN_ID, ${LAUNCH_LABEL}): $APP"
# The designated requirement is what TCC keys the Accessibility grant on.
# Compare this block between two try-pr runs: identical DR => the grant
# survives; a DR that changes every run (ad-hoc pins the per-build cdhash) is
# exactly why the app has to be re-added in System Settings each time.
echo "Designated requirement (compare across try-pr runs — stable == TCC grant survives):"
codesign -d --requirements - "$APP" 2>&1 | sed 's/^/  /' || true
if [[ "$SIGNER" == "Authority=ad-hoc" ]]; then
  echo "NOTE: ad-hoc signed build — if text insertion fails, remove and re-add"
  echo "      localvoxtral in System Settings > Privacy & Security > Accessibility"
  echo "      (TCC grants don't survive ad-hoc signature changes)."
  echo "      For a SAME-REPO PR this is unexpected: CI should identity-sign it."
  echo "      An ad-hoc same-repo artifact means the self-hosted runner user lost"
  echo "      the localvoxtral-dev cert (check: security find-identity -v -p codesigning)."
fi
open "$APP"
