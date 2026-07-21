#!/bin/bash
# Decides whether the normal CI job may take the docs/scripts-only fast path.
#
# Usage:
#   scripts/ci/docs-only-filter.sh <changed-files-file>
#
#   <changed-files-file>  one changed path per line (git diff --name-only)
#
# stdout is $GITHUB_OUTPUT-shaped:
#   docs_only=true|false
#   count=<number of non-empty changed paths>
#   reason=<one line, safe for a step summary>
#
# Exits 0 for both decisions; non-zero only on usage errors. The workflow owns
# fail-open behavior when it cannot compute the diff or invoke this filter.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <changed-files-file>" >&2
  exit 2
fi

CHANGED_FILES_FILE="$1"
if [[ ! -f "$CHANGED_FILES_FILE" ]]; then
  echo "changed-files file not found: $CHANGED_FILES_FILE" >&2
  exit 2
fi

emit_full_run() {
  local reason="$1"
  local count="$2"
  echo "docs_only=false"
  echo "count=$count"
  echo "reason=$reason"
}

# This is an allowlist, not a list of known-dangerous paths: an unknown path
# must run full CI. Exclusions are checked first so a Markdown suffix cannot
# make workflow, source, package, or CI-control files eligible.
#
# scripts/ci/** is intentionally excluded. That includes this filter, so every
# edit to CI decision logic proves the full workflow on its first real run.
# scripts/package_app.sh is also excluded because tier 0 directly exercises it.
# scripts/mac/localvoxtral-build-gate.sh remains eligible: it is deployed and
# run out of band rather than exercised by tier-0 Swift/package lanes.
REJECTION_REASON=""
is_fast_path_allowlisted() {
  local path="$1"

  case "$path" in
    .github/*)
      REJECTION_REASON="workflow path: $path"
      return 1
      ;;
    scripts/ci/*)
      REJECTION_REASON="CI decision path: $path"
      return 1
      ;;
    scripts/package_app.sh)
      REJECTION_REASON="tier-0 packaging path: $path"
      return 1
      ;;
    scripts/mac/lv-test-servers.sh)
      # Only exercised by the (gated) warm + integration steps — no un-gated
      # shell test covers it, unlike the build gate. Full run.
      REJECTION_REASON="warm-infra path with gated-only coverage: $path"
      return 1
      ;;
    assets/icons/*)
      # package_app.sh hard-requires and transforms these (app + menubar
      # icons); an icon-only diff must prove the gated package step.
      REJECTION_REASON="packaging input path: $path"
      return 1
      ;;
    # ORDER MATTERS: this arm must precede `Package.*` so helper manifests
    # (PolishHelper/Package.swift) are caught here; `Package.*` then only
    # matches the root manifest/lockfile.
    Sources/*|Tests/*|PolishHelper/*|SpeechHelper/*)
      REJECTION_REASON="Swift source/test/helper path: $path"
      return 1
      ;;
    Package.*)
      REJECTION_REASON="Swift package manifest/lock path: $path"
      return 1
      ;;
    *.toml)
      REJECTION_REASON="bundled/config TOML path: $path"
      return 1
      ;;
    integrations/*)
      if [[ "$path" == *.md ]]; then
        return 0
      fi
      REJECTION_REASON="shipped integration path: $path"
      return 1
      ;;
    EvalRecordings/*|EvalCorpus/*)
      if [[ "$path" == *.md ]]; then
        return 0
      fi
      REJECTION_REASON="evaluation data/code path: $path"
      return 1
      ;;
    *.md|scripts/*|assets/*|LICENSE|.gitignore)
      return 0
      ;;
    *)
      REJECTION_REASON="path is not allowlisted: $path"
      return 1
      ;;
  esac
}

count=0
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  count=$((count + 1))
  if ! is_fast_path_allowlisted "$file"; then
    emit_full_run "$REJECTION_REASON" "$count"
    exit 0
  fi
done <"$CHANGED_FILES_FILE"

if [[ "$count" -eq 0 ]]; then
  emit_full_run "empty changed-file list — failing open" 0
  exit 0
fi

# Invariant: the fast-path allowlist and both live-model lane path lists must
# be disjoint. Reuse the authoritative filters so future additions there
# automatically force full CI here. This notably excludes LLM-relevant
# Markdown under EvalCorpus/ or integrations/claude-code/ even though ordinary
# Markdown in those parent trees is otherwise eligible.
if ! llm_decision="$("$(dirname "$0")/llm-lane-filter.sh" "$CHANGED_FILES_FILE")"; then
  emit_full_run "LLM lane filter failed — failing open" "$count"
  exit 0
fi
if [[ "$(sed -n 's/^run=//p' <<<"$llm_decision")" == "true" ]]; then
  llm_reason="$(sed -n 's/^reason=//p' <<<"$llm_decision")"
  emit_full_run "LLM-lane-relevant path: $llm_reason" "$count"
  exit 0
fi

if ! speechd_decision="$("$(dirname "$0")/speechd-lane-filter.sh" "$CHANGED_FILES_FILE")"; then
  emit_full_run "speechd lane filter failed — failing open" "$count"
  exit 0
fi
if [[ "$(sed -n 's/^run=//p' <<<"$speechd_decision")" == "true" ]]; then
  speechd_reason="$(sed -n 's/^reason=//p' <<<"$speechd_decision")"
  emit_full_run "speechd-lane-relevant path: $speechd_reason" "$count"
  exit 0
fi

echo "docs_only=true"
echo "count=$count"
echo "reason=all $count changed path(s) are docs/scripts-only"
