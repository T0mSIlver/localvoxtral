#!/bin/bash
# Decides whether the normal CI job may take the docs/scripts-only fast path.
#
# Usage:
#   scripts/ci/docs-only-filter.sh <changed-files-file>
#   scripts/ci/docs-only-filter.sh --list-eligible <paths-file>
#
#   <changed-files-file>  one changed path per line (git diff --name-only)
#   --list-eligible       print the paths the allowlist below admits, and
#                         nothing else (test-docs-only-filter.sh uses it)
#
# stdout is $GITHUB_OUTPUT-shaped:
#   docs_only=true|false
#   count=<number of non-empty changed paths>
#   reason=<one line, safe for a step summary>
#
# Exits 0 for both decisions; non-zero only on usage errors. The workflow owns
# fail-open behavior when it cannot compute the diff or invoke this filter.
set -euo pipefail

LIST_ELIGIBLE=false
if [[ $# -eq 2 && "$1" == "--list-eligible" ]]; then
  LIST_ELIGIBLE=true
  shift
fi
if [[ $# -ne 1 ]]; then
  echo "usage: $0 [--list-eligible] <changed-files-file>" >&2
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

if [[ "$LIST_ELIGIBLE" == "true" ]]; then
  while IFS= read -r file; do
    [[ -n "$file" ]] && is_fast_path_allowlisted "$file" && printf '%s\n' "$file"
  done <"$CHANGED_FILES_FILE"
  exit 0
fi

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

# Some fast-path files are test input: app-target tests match sentences of
# integrations/claude-code/README.md, check the docs' screenshot references,
# and so on (#707). A diff that changes one must run the suites that read it.
# The list is derived, not kept: every path a Swift test names outside a //
# comment counts as read. scripts/ci/test-reads.txt adds the reads a scan for
# names cannot see (a bare file name joined onto a directory, a directory
# walk), and test-docs-only-filter.sh fails when a test adds such a read
# without a line there. LV_DOCS_FILTER_ROOT points the scan at a fixture tree.
ROOT_DIR="${LV_DOCS_FILTER_ROOT:-$(cd "$(dirname "$0")/../.." && pwd -P)}"
TEST_READS_FILE="$ROOT_DIR/scripts/ci/test-reads.txt"
if [[ ! -d "$ROOT_DIR/Tests" || ! -f "$TEST_READS_FILE" ]]; then
  emit_full_run "Tests/ or scripts/ci/test-reads.txt missing — failing open" "$count"
  exit 0
fi
TOKENS_FILE="$(mktemp "${TMPDIR:-/tmp}/lv-docs-only-tokens.XXXXXX")"
trap 'rm -f "$TOKENS_FILE"' EXIT
# path_tokens: the path-shaped words of Swift source on stdin, outside //
# comments. Leading /, ./ and ../ are stripped so "\(root)/docs/x.md" still
# names docs/x.md. A path in a fixture string counts too; that only costs the
# fast path.
path_tokens() {
  grep -vE '^[[:space:]]*//' \
    | grep -oE '[A-Za-z0-9_./-]+' \
    | sed -E 's#^(\.{0,2}/)+##' \
    | sort -u
}
if ! find "$ROOT_DIR/Tests" -name '*.swift' -type f -exec cat {} + \
    | path_tokens >"$TOKENS_FILE" \
    || [[ ! -s "$TOKENS_FILE" ]]; then
  emit_full_run "scan of Tests/ for read paths failed — failing open" "$count"
  exit 0
fi

# references_png <path>: true when the file references a relative
# assets/*.png the way DocsReferencedAssetsTests matches them.
references_png() {
  grep -qE '[("](\.\./)*assets/[^)"'"'"'[:space:]]+\.png' "$ROOT_DIR/$1"
}

# first_reader <path>: the first test file that names <path>, for the reason.
first_reader() {
  local test_file tokens
  while IFS= read -r test_file; do
    # Not piped into grep -q: an early exit would SIGPIPE sort under pipefail.
    tokens="$(path_tokens <"$test_file" || true)"
    if grep -qxF -- "$1" <<<"$tokens"; then
      printf '%s\n' "${test_file#"$ROOT_DIR/"}"
      return 0
    fi
  # Only files holding the string can name it; one grep finds them, so the
  # per-file scan forks for a handful of files, not every test file.
  done < <(grep -rlF --include='*.swift' -- "$1" "$ROOT_DIR/Tests" | sort || true)
  printf 'Tests/\n'
}

# declared_read <path>: sets READ_BY to the test that reads <path> through a
# test-reads.txt line, or returns 1.
READ_BY=""
declared_read() {
  local path="$1" test_file token kind globs glob
  # shellcheck disable=SC2034  # token is read to skip the column
  while read -r test_file token kind globs; do
    [[ -z "$test_file" || "$test_file" == \#* || "$kind" == "none" ]] && continue
    # Split on spaces without expanding the globs against the checkout.
    set -f
    # shellcheck disable=SC2086
    set -- $globs
    set +f
    for glob in "$@"; do
      # Unquoted on purpose: the right-hand side is a pattern.
      # shellcheck disable=SC2053
      [[ "$path" == $glob ]] || continue
      case "$kind" in
        read) ;;
        png-refs)
          [[ ! -f "$ROOT_DIR/$path" ]] || references_png "$path" || continue
          ;;
        deleted)
          [[ ! -e "$ROOT_DIR/$path" ]] || continue
          ;;
        *)
          # An unknown kind is a table bug; read it as a read.
          ;;
      esac
      READ_BY="$test_file ($kind)"
      return 0
    done
  done <"$TEST_READS_FILE"
  return 1
}

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  if grep -qxF -- "$file" "$TOKENS_FILE"; then
    emit_full_run "a test names $file ($(first_reader "$file"))" "$count"
    exit 0
  fi
  if declared_read "$file"; then
    emit_full_run "a test reads $file ($READ_BY, scripts/ci/test-reads.txt)" "$count"
    exit 0
  fi
done <"$CHANGED_FILES_FILE"

echo "docs_only=true"
echo "count=$count"
echo "reason=all $count changed path(s) are docs/scripts-only"
