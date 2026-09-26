#!/bin/bash
# Regression test for docs-only-filter.sh: which diffs may skip the Swift
# suites. Changed-file lists are written to temp files; no network. /bin/bash,
# like the filter, so build-test runs both under macOS's bash 3.2.
#
# What it pins:
#   - the allowlist's two sides (a docs page and the PR template take the
#     fast path; workflow, source and empty diffs do not)
#   - #707: a Markdown file a Swift test reads runs full CI, whether the test
#     names its path, joins a bare file name onto a directory
#     (scripts/ci/test-reads.txt) or walks docs/ for screenshot references
#   - the derivation itself, on a fixture tree: a path named in code counts, a
#     path named only in a // comment does not, and a missing Tests/ fails open
#   - scripts/ci/test-reads.txt is complete: a test file that reaches the repo
#     root and names a bare file name some fast-path file has, or walks a
#     directory, needs a line there; a line whose token is gone is stale.
#     The same check is run on a fixture to show it fails.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
FILTER="$ROOT_DIR/scripts/ci/docs-only-filter.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-docs-only-filter-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
printf 'bash %s\n' "$BASH_VERSION"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# expect <true|false> <description> [--root <dir>] <changed-path>...
expect() {
  local expected="$1" description="$2"
  shift 2
  local changed="$TMP_DIR/changed" root=""
  : >"$changed"
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--root" ]]; then
      root="$2"
      shift 2
      continue
    fi
    printf '%s\n' "$1" >>"$changed"
    shift
  done
  local output
  if [[ -n "$root" ]]; then
    output="$(LV_DOCS_FILTER_ROOT="$root" "$FILTER" "$changed")" \
      || fail "$description: filter exited non-zero"
  else
    output="$("$FILTER" "$changed")" || fail "$description: filter exited non-zero"
  fi
  local docs_only reason
  docs_only="$(sed -n 's/^docs_only=//p' <<<"$output")"
  reason="$(sed -n 's/^reason=//p' <<<"$output")"
  [[ "$docs_only" == "$expected" ]] \
    || fail "$description: expected docs_only=$expected, got docs_only=$docs_only ($reason)"
  [[ -n "$reason" ]] || fail "$description: reason line is missing"
  printf 'PASS: %s (%s)\n' "$description" "$reason"
}

# --- The allowlist -----------------------------------------------------------

expect true "a docs page no test reads keeps the fast path" docs/roadmap.md
expect true "an integration README no test reads keeps the fast path" \
  integrations/vibe/README.md
expect false "a workflow edit runs full CI" .github/workflows/ci.yml
expect true "the PR template keeps the fast path" .github/pull_request_template.md
expect false "the PR template with a workflow runs full CI" \
  .github/pull_request_template.md .github/workflows/ci.yml
expect false "a Swift source edit runs full CI" Sources/localvoxtral/App.swift
expect false "an empty diff fails open"

# --- #707: Markdown the tests read --------------------------------------------

expect false "integrations/claude-code/README.md: ClaudeRemoteEnrollmentServiceTests names it" \
  integrations/claude-code/README.md
expect false "docs/remote-claude-context.md: ClaudeRemoteEnrollmentServiceTests names it" \
  docs/remote-claude-context.md
expect false "integrations/opencode/README.md: OpencodePluginManifestTests joins README.md on" \
  integrations/opencode/README.md
expect false "docs/agent/test-tiers.md: AgentsGuideSizeTests names it" \
  docs/agent/test-tiers.md
expect false "docs/dictation.md: DocsReferencedAssetsTests checks its screenshots" \
  docs/dictation.md
expect false "one test-read page among free pages runs full CI" \
  docs/roadmap.md integrations/claude-code/README.md
expect false "scripts/ui-smoke.sh: SettingsTabTests names it" scripts/ui-smoke.sh

# --- The derivation, on a fixture tree ---------------------------------------

FIXTURE="$TMP_DIR/fixture"
mkdir -p "$FIXTURE/Tests/AppTests" "$FIXTURE/scripts/ci" "$FIXTURE/docs" "$FIXTURE/assets"
cat >"$FIXTURE/Tests/AppTests/ReaderTests.swift" <<'SWIFT'
final class ReaderTests: XCTestCase {
    // docs/commented.md is only mentioned here.
    /// So is docs/doc-commented.md.
    func testReads() throws {
        _ = try String(contentsOf: root.appendingPathComponent("docs/named.md"))
        _ = "\(root)/docs/interpolated.md"
    }
}
SWIFT
cat >"$FIXTURE/scripts/ci/test-reads.txt" <<'TABLE'
# comment line
Tests/AppTests/ReaderTests.swift enumerator( png-refs docs/walked/*.md
Tests/AppTests/ReaderTests.swift enumerator( deleted assets/*.png
Tests/AppTests/ReaderTests.swift notes.md none docs/notes.md
TABLE
mkdir -p "$FIXTURE/docs/walked"
printf 'See ![pane](../../assets/pane.png).\n' >"$FIXTURE/docs/walked/shots.md"
printf '<img src="../../assets/pane.png">\n' >"$FIXTURE/docs/walked/html-shots.md"
printf 'No pictures, and https://example.com/assets/x.png is absolute.\n' \
  >"$FIXTURE/docs/walked/plain.md"
printf 'png\n' >"$FIXTURE/assets/pane.png"

expect false "a path a test names in code is read" --root "$FIXTURE" docs/named.md
expect false "an interpolated root prefix still names the path" --root "$FIXTURE" \
  docs/interpolated.md
expect true "a path named only in a // comment is not read" --root "$FIXTURE" docs/commented.md
expect true "a path named only in a /// comment is not read" --root "$FIXTURE" \
  docs/doc-commented.md
expect false "png-refs: a walked page with a markdown screenshot" --root "$FIXTURE" \
  docs/walked/shots.md
expect false "png-refs: a walked page with an HTML screenshot" --root "$FIXTURE" \
  docs/walked/html-shots.md
expect true "png-refs: a walked page with no relative screenshot" --root "$FIXTURE" \
  docs/walked/plain.md
expect false "png-refs: a deleted walked page" --root "$FIXTURE" docs/walked/gone.md
expect true "deleted: a screenshot that is still there" --root "$FIXTURE" assets/pane.png
expect false "deleted: a screenshot that is gone" --root "$FIXTURE" assets/gone.png
expect true "a none line reads nothing" --root "$FIXTURE" docs/notes.md

NO_TESTS="$TMP_DIR/no-tests"
mkdir -p "$NO_TESTS/scripts/ci"
: >"$NO_TESTS/scripts/ci/test-reads.txt"
expect false "no Tests/ fails open" --root "$NO_TESTS" docs/roadmap.md

# --- scripts/ci/test-reads.txt is complete ------------------------------------

# A test file "reaches the repo root" when it names one of these; the reads
# the name scan cannot see all start from one.
ROOT_ANCHORS='#filePath|repositoryRoot|repoRoot|ClaudePluginAssets\.development|rootMarketplaceURL'
WALK_CALLS='(enumerator|contentsOfDirectory|subpathsOfDirectory|subpaths)\('

# undeclared_reads <root>: prints "<test file> <token>" for each read in
# <root>/Tests that the name scan cannot see and <root>/scripts/ci/test-reads.txt
# does not declare, then "stale: <line>" for each table line whose token is gone.
undeclared_reads() {
  local root="$1" table="$1/scripts/ci/test-reads.txt"
  local files="$TMP_DIR/files" eligible="$TMP_DIR/eligible-names"
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root" ls-files >"$files"
  else
    (cd "$root" && find . -type f | sed 's#^\./##') >"$files"
  fi
  "$FILTER" --list-eligible "$files" | sed 's#.*/##' | sort -u >"$eligible"

  local test_file code token
  while IFS= read -r test_file; do
    code="$(grep -vE '^[[:space:]]*//' "$root/$test_file" || true)"
    grep -qE "$ROOT_ANCHORS" <<<"$code" || continue
    {
      grep -oE '"[A-Za-z0-9_./-]+\.[A-Za-z0-9]+"' <<<"$code" | tr -d '"' || true
      grep -oE "$WALK_CALLS" <<<"$code" || true
    } | sort -u | while IFS= read -r token; do
      case "$token" in
        *\()
          ;;
        *)
          # A tracked path is visible to the name scan; a bare name joined
          # onto a directory is not, if a fast-path file shares it.
          grep -qxF -- "$token" "$files" && continue
          grep -qxF -- "${token##*/}" "$eligible" || continue
          ;;
      esac
      awk -v f="$test_file" -v t="$token" '$1 == f && $2 == t { found = 1 } END { exit !found }' \
        "$table" || printf '%s %s\n' "$test_file" "$token"
    done
  # One grep narrows to the files that name an anchor at all; the loop then
  # drops those that name one only in a comment.
  done < <(cd "$root" && grep -rlE --include='*.swift' "$ROOT_ANCHORS" Tests | sort || true)

  local line
  while read -r test_file token line; do
    [[ -z "$test_file" || "$test_file" == \#* ]] && continue
    code=""
    [[ -f "$root/$test_file" ]] && code="$(grep -vE '^[[:space:]]*//' "$root/$test_file" || true)"
    # A here-string, not a pipe: grep -q exiting early would SIGPIPE the
    # writer and fail the pipeline under pipefail.
    if ! grep -qF -- "$token" <<<"$code"; then
      printf 'stale: %s %s\n' "$test_file" "$token"
    fi
  done <"$table"
}

missing="$(undeclared_reads "$ROOT_DIR")"
[[ -z "$missing" ]] || fail "scripts/ci/test-reads.txt lacks reads the name scan cannot see (add a line saying what each reads, or none):
$missing"
printf 'PASS: scripts/ci/test-reads.txt declares every hidden read in Tests/\n'

# The check has teeth: a new test that joins a fast-path file's name onto a
# directory, or walks one, is reported until the table has its line; a line
# for a token no test has is reported as stale.
cat >"$FIXTURE/Tests/AppTests/NewTests.swift" <<'SWIFT'
final class NewTests: XCTestCase {
    func testReadsTheGuide() throws {
        let root = URL(fileURLWithPath: #filePath)
        _ = try String(contentsOf: root.appendingPathComponent("docs").appendingPathComponent("guide.md"))
        _ = FileManager.default.subpathsOfDirectory(atPath: root.path)
        _ = "scratch.md"
    }
}
SWIFT
printf 'guide\n' >"$FIXTURE/docs/guide.md"
missing="$(undeclared_reads "$FIXTURE")"
expected_missing="Tests/AppTests/NewTests.swift guide.md
Tests/AppTests/NewTests.swift subpathsOfDirectory(
stale: Tests/AppTests/ReaderTests.swift enumerator(
stale: Tests/AppTests/ReaderTests.swift enumerator(
stale: Tests/AppTests/ReaderTests.swift notes.md"
[[ "$missing" == "$expected_missing" ]] \
  || fail "the completeness check on a fixture reported:
$missing
expected:
$expected_missing"
printf 'PASS: the completeness check reports an undeclared read and stale lines\n'

printf 'All docs-only-filter checks passed.\n'
