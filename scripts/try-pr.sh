#!/usr/bin/env bash
set -euo pipefail

# Download the CI-built app for a PR (or main) and launch it, for fast manual
# testing of UI/behavior that automated tests can't cover. Runs on macOS; the
# artifact is the exact bundle CI built and smoke-tested for that revision.
#
# Usage:
#   ./scripts/try-pr.sh <pr-number>   # e.g. ./scripts/try-pr.sh 30
#   ./scripts/try-pr.sh main          # latest green build of main
#
# Requires: gh (authenticated). Artifacts exist for CI runs made after the
# artifact-upload step landed; use "gh run rerun <run-id>" on older PRs.

if [[ "$(uname)" != "Darwin" ]]; then
  echo "This script launches a macOS app bundle — run it on the Mac." >&2
  exit 1
fi

TARGET="${1:?usage: $0 <pr-number|main>}"

if [[ "$TARGET" == "main" ]]; then
  RUN_ID="$(gh run list --workflow CI --branch main --status success --limit 1 \
    --json databaseId --jq '.[0].databaseId')"
else
  HEAD_SHA="$(gh pr view "$TARGET" --json headRefOid --jq .headRefOid)"
  RUN_ID="$(gh run list --workflow CI --commit "$HEAD_SHA" --status success --limit 1 \
    --json databaseId --jq '.[0].databaseId')"
fi

if [[ -z "$RUN_ID" || "$RUN_ID" == "null" ]]; then
  echo "No successful CI run found for '$TARGET' with a downloadable build." >&2
  echo "If the PR predates artifact uploads, re-run its checks: gh pr checks $TARGET / gh run rerun" >&2
  exit 1
fi

DEST="$(mktemp -d /tmp/localvoxtral-try.XXXXXX)"
gh run download "$RUN_ID" -n localvoxtral-app -D "$DEST"
ditto -x -k "$DEST/localvoxtral-app.zip" "$DEST/extracted"
APP="$DEST/extracted/localvoxtral.app"
xattr -cr "$APP" 2>/dev/null || true

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
echo "Launching build of '$TARGET' (CI run $RUN_ID, ${SIGNER}): $APP"
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
