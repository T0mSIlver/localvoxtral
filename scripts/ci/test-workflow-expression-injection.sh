#!/bin/bash
# Regression test: no workflow `run:` block expands text someone other than
# the workflow author chose through `${{ }}`, and the release builds the
# commit it was dispatched on.
#
# GitHub substitutes `${{ }}` into the script before bash parses it, so a
# branch named `audit$(id)` ran `id` on the owner's Mac from release.yml's
# summary lines (#1489). Such values go through `env:` (or GitHub's own
# GITHUB_REF_NAME) and are expanded as quoted shell variables. Forbidden in
# `run:`: github.ref_name, github.ref, github.head_ref, github.base_ref and
# anything under github.event.
#
# release.yml checked out `ref: github.ref_name`, which resolves to the
# branch tip when the Mac job starts. A push in between shipped a commit the
# e2e dictation check never passed on (#1490); the checkout pins github.sha.
#
# Pure bash and awk, no YAML library, like test-workflow-step-names.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW_DIR="$ROOT_DIR/.github/workflows"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-workflow-injection-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# Prints "<line>: <text>" for each `run:` line holding a forbidden expression.
# A block `run: |` lasts while lines are indented deeper than the `run:` key.
forbidden_expansions() {
  awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function report(s) {
      if (s ~ /\$\{\{[^}]*github\.(ref_name|ref|head_ref|base_ref|event)([^A-Za-z0-9_]|$)/)
        print FNR ": " s
    }
    {
      if (in_run) {
        if ($0 ~ /^[[:space:]]*$/) next
        if (indent($0) > run_indent) { report($0); next }
        in_run = 0
      }
      if ($0 ~ /^[[:space:]]*(- )?run:[[:space:]]*[|>][-+]?[[:space:]]*$/) {
        in_run = 1
        run_indent = indent($0)
        if ($0 ~ /^[[:space:]]*- /) run_indent += 2
        next
      }
      if ($0 ~ /^[[:space:]]*(- )?run:/) report($0)
    }
  ' "$1"
}

failures=0

# The scanner itself: it must catch block and one-line forms, and leave env:
# mappings and `if:` expressions alone.
cat >"$TMP_DIR/fixture.yml" <<'EOF'
jobs:
  j:
    steps:
      - name: safe
        env:
          REF: ${{ github.ref_name }}
        if: github.ref_name == 'main'
        run: echo "$REF"
      - name: block
        run: |
          set -eu
          echo "from ${{ github.ref_name }}"

          echo "${{ github.event.pull_request.title }}"
      - name: one-line
        run: echo ${{ github.head_ref }}
      - name: after
        env:
          X: ${{ github.event.before }}
        run: echo "$X ${{ github.sha }} ${{ github.repository }}"
EOF
fixture_hits="$(forbidden_expansions "$TMP_DIR/fixture.yml" | cut -d: -f1 | tr '\n' ' ')"
if [[ "$fixture_hits" != "12 14 16 " ]]; then
  echo "FAIL: the scanner flagged lines '$fixture_hits' in its fixture, expected '12 14 16 '" >&2
  failures=$((failures + 1))
fi

for file in "$WORKFLOW_DIR"/*.yml; do
  [[ -e "$file" ]] || continue
  hits="$(forbidden_expansions "$file")"
  if [[ -n "$hits" ]]; then
    echo "FAIL: $(basename "$file") expands caller-chosen text inside run: (pass it through env:):" >&2
    sed 's/^/  /' <<<"$hits" >&2
    failures=$((failures + 1))
  fi
done

# The release's first checkout: the step after "Checkout release ref" up to
# the next step names the ref it builds.
release_ref="$(awk '
  /- name: Checkout release ref/ { in_step = 1; next }
  in_step && /^[[:space:]]+- name: / { exit }
  in_step && /^[[:space:]]+ref:/ { sub(/^[[:space:]]+ref:[[:space:]]*/, ""); print; exit }
' "$WORKFLOW_DIR/release.yml")"
if [[ "$release_ref" != '${{ github.sha }}' ]]; then
  echo "FAIL: release.yml checks out '${release_ref:-<no ref>}', not the dispatched commit '\${{ github.sha }}'" >&2
  failures=$((failures + 1))
fi

if (( failures > 0 )); then
  exit 1
fi
echo "PASS: no run: block expands caller-chosen text; the release checks out github.sha"
