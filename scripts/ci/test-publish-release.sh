#!/usr/bin/env bash
# Tests publish-release.sh, and `release.sh publish`, which reruns it on a
# release run's artifact (#1555), against a stub gh on PATH that keeps the
# repo's releases in a JSON file (needs jq). No network, runs on Linux.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$ROOT_DIR/scripts/ci/publish-release.sh"
RELEASE="$ROOT_DIR/scripts/release.sh"
REPO="T0mSIlver/localvoxtral"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-publish-release-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Stub gh. State lives in $SCEN: releases.json (the repo's releases), tags
# (one per line), fail-<key> (how many more calls of that kind fail, or
# "always"), calls (one line per call).
set -euo pipefail
: "${SCEN:?}"
printf '%s\n' "$*" >>"$SCEN/calls"
R="$SCEN/releases.json"

# fails <key>: true when this call should fail, counting the budget down.
fails() {
  local f="$SCEN/fail-$1" n
  [[ -f "$f" ]] || return 1
  n="$(cat "$f")"
  [[ "$n" == "always" ]] && return 0
  (( n > 0 )) || return 1
  echo $((n - 1)) >"$f"
}
network_error() { echo "error connecting to $1: dial tcp: lookup $1: getaddrinfo ENOTFOUND $1" >&2; exit 1; }

if [[ "$1" == "release" && "$2" == "upload" ]]; then
  tag="$3" path="$4" name="$(basename "$4")"
  fails "upload-$name" && network_error uploads.github.com
  size="$(wc -c <"$path" | tr -d ' ')"
  jq --arg t "$tag" --arg n "$name" --argjson s "$size" '
    map(if .tag_name == $t
        then .assets = ([.assets[] | select(.name != $n)] + [{name: $n, size: $s, state: "uploaded"}])
        else . end)' "$R" >"$R.new"
  mv "$R.new" "$R"
  exit 0
fi

if [[ "$1" == "run" && "$2" == "download" ]]; then
  # gh run download <id> -n <name> -D <dir>
  fails download && network_error api.github.com
  cp "$SCEN/artifact/"* "$7/"
  exit 0
fi

if [[ "$1" == "workflow" && "$2" == "run" ]]; then
  exit 0
fi

[[ "$1" == "api" ]] || { echo "stub gh: unhandled: $*" >&2; exit 64; }
shift
method=GET url="" jq_filter="" fields=()
while (( $# )); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --jq) jq_filter="$2"; shift 2 ;;
    -f|-F) fields+=("$2"); shift 2 ;;
    --silent) shift ;;
    *) url="$1"; shift ;;
  esac
done
# field <name>: the value passed for it, reading @file values.
field() {
  local kv
  for kv in "${fields[@]}"; do
    if [[ "${kv%%=*}" == "$1" ]]; then
      local v="${kv#*=}"
      if [[ "$v" == @* ]]; then cat "${v#@}"; else printf '%s' "$v"; fi
      return
    fi
  done
}
case "$method $url" in
  "GET repos/"*"/git/ref/tags/"*)
    fails tag && network_error api.github.com
    grep -qxF "${url##*/}" "$SCEN/tags" || { echo "HTTP 404: Not Found" >&2; exit 1; }
    ;;
  "GET repos/"*"/releases?per_page=100")
    fails list && network_error api.github.com
    jq -r "$jq_filter" "$R"
    ;;
  "GET repos/"*"/actions/artifacts?"*)
    jq -r "$jq_filter" "$SCEN/artifacts.json"
    ;;
  "POST repos/"*"/releases")
    fails create && network_error api.github.com
    id=$((100 + $(jq length "$R")))
    jq --argjson id "$id" --arg t "$(field tag_name)" --arg n "$(field name)" \
       --argjson d "$(field draft)" --argjson p "$(field prerelease)" \
       --arg l "$(field make_latest)" --arg b "$(field body)" \
       --argjson g "$(field generate_release_notes)" '
      [{id: $id, tag_name: $t, name: $n, draft: $d, prerelease: $p,
        make_latest: $l, body: $b, generate_release_notes: $g, assets: []}] + .' \
       "$R" >"$R.new"
    mv "$R.new" "$R"
    ;;
  "PATCH repos/"*"/releases/"*)
    fails publish && network_error api.github.com
    jq --argjson id "${url##*/}" --argjson d "$(field draft)" --arg l "$(field make_latest)" '
      map(if .id == $id then .draft = $d | .make_latest = $l else . end)' "$R" >"$R.new"
    mv "$R.new" "$R"
    ;;
  *)
    echo "stub gh: unhandled api call: $method $url" >&2; exit 64 ;;
esac
STUB
chmod +x "$TMP_DIR/bin/gh"

# build_assets <dir> <tag>: the seven files release.yml builds.
build_assets() {
  local dir="$1" tag="$2" name
  mkdir -p "$dir"
  for name in "localvoxtral-$tag.zip" "localvoxtral-$tag.dmg" "localvoxtral-$tag.dSYM.zip" \
      "localvoxtral-polishd-$tag.dSYM.zip" "localvoxtral-speechd-$tag.dSYM.zip"; do
    printf 'contents of %s\n' "$name" >"$dir/$name"
  done
  (cd "$dir" && sha256sum "localvoxtral-$tag.zip" >"localvoxtral-$tag.zip.sha256" \
    && sha256sum "localvoxtral-$tag.dmg" >"localvoxtral-$tag.dmg.sha256")
  printf 'Signed with Developer ID and notarized by Apple.\n' >"$dir/localvoxtral-$tag.release-notes.md"
}

# scenario <tag>: a fresh $SCEN where <tag> is pushed and has no release.
scenario() {
  SCEN="$TMP_DIR/scen-$RANDOM$RANDOM"
  mkdir -p "$SCEN"
  echo '[]' >"$SCEN/releases.json"
  echo "$1" >"$SCEN/tags"
  : >"$SCEN/calls"
  DIST="$SCEN/dist"
  build_assets "$DIST" "$1"
}

# publish <expected exit> <description> <tag>
publish() {
  local expected="$1" tag="$3" rc=0
  DESCRIPTION="$2"
  OUTPUT="$(SCEN="$SCEN" GITHUB_REPOSITORY="$REPO" PUBLISH_RETRY_DELAY=0 \
    PATH="$TMP_DIR/bin:$PATH" "$SCRIPT" "$tag" "$DIST" "$DIST/localvoxtral-$tag.release-notes.md" 2>&1)" || rc=$?
  [[ "$rc" == "$expected" ]] || fail "$DESCRIPTION: expected exit $expected, got $rc. Output: $OUTPUT"
}
release_jq() { jq -r "$1" "$SCEN/releases.json"; }
expect_eq() { [[ "$2" == "$3" ]] || fail "$DESCRIPTION: $1 is '$2', expected '$3'. Output: $OUTPUT"; }
contains() { grep -qF -- "$1" <<<"$OUTPUT" || fail "$DESCRIPTION: output lacks '$1'. Output: $OUTPUT"; }
calls_matching() { grep -cF -- "$1" "$SCEN/calls" || true; }
pass() { printf 'PASS: %s\n' "$DESCRIPTION"; }

TAG=v0.13.0

scenario "$TAG"
echo 2 >"$SCEN/fail-upload-localvoxtral-$TAG.zip"
publish 0 "an upload that fails twice on DNS then succeeds publishes the release" "$TAG"
contains "Uploading localvoxtral-$TAG.zip failed (attempt 1 of 5)"
contains "Uploading localvoxtral-$TAG.zip failed (attempt 2 of 5)"
expect_eq "zip upload calls" "$(calls_matching "release upload $TAG $DIST/localvoxtral-$TAG.zip ")" 3
expect_eq "assets" "$(release_jq '.[0].assets | length')" 7
expect_eq "draft" "$(release_jq '.[0].draft')" false
expect_eq "make_latest" "$(release_jq '.[0].make_latest')" true
expect_eq "prerelease" "$(release_jq '.[0].prerelease')" false
expect_eq "name" "$(release_jq '.[0].name')" "localvoxtral $TAG"
expect_eq "generated notes" "$(release_jq '.[0].generate_release_notes')" true
expect_eq "body" "$(release_jq '.[0].body')" "Signed with Developer ID and notarized by Apple."
grep -qF -- "-F draft=true" "$SCEN/calls" || fail "$DESCRIPTION: the release was not created as a draft"
pass

scenario "$TAG"
echo always >"$SCEN/fail-upload-localvoxtral-$TAG.zip"
publish 1 "an upload that never succeeds leaves a draft and names the resume command" "$TAG"
contains "Uploading localvoxtral-$TAG.zip failed 5 times; giving up"
contains "lacks, or holds at another size: localvoxtral-$TAG.zip. It stays a draft; rerun ./scripts/release.sh publish $TAG"
expect_eq "assets" "$(release_jq '.[0].assets | length')" 6
expect_eq "draft" "$(release_jq '.[0].draft')" true
expect_eq "publish calls" "$(calls_matching "-X PATCH")" 0
pass

# The resume: the same files, against the draft the failed run left.
rm "$SCEN/fail-upload-localvoxtral-$TAG.zip"
: >"$SCEN/calls"
publish 0 "a rerun uploads only what the draft lacks and publishes it" "$TAG"
expect_eq "uploads" "$(calls_matching "release upload")" 1
expect_eq "zip uploads" "$(calls_matching "release upload $TAG $DIST/localvoxtral-$TAG.zip ")" 1
expect_eq "creates" "$(calls_matching "-X POST")" 0
expect_eq "releases" "$(release_jq 'length')" 1
expect_eq "draft" "$(release_jq '.[0].draft')" false
expect_eq "assets" "$(release_jq '.[0].assets | length')" 7
pass

: >"$SCEN/calls"
publish 0 "a rerun on a complete published release changes nothing" "$TAG"
contains "already published"
expect_eq "uploads" "$(calls_matching "release upload")" 0
expect_eq "writes" "$(calls_matching "-X ")" 0
pass

scenario "$TAG"
publish 0 "seed a published release" "$TAG"
jq '.[0].assets |= map(if .name | endswith(".dmg") then .size = 3 else . end)' \
  "$SCEN/releases.json" >"$SCEN/r.json" && mv "$SCEN/r.json" "$SCEN/releases.json"
: >"$SCEN/calls"
publish 0 "an asset held at another size is uploaded again" "$TAG"
expect_eq "uploads" "$(calls_matching "release upload")" 1
expect_eq "dmg uploads" "$(calls_matching "release upload $TAG $DIST/localvoxtral-$TAG.dmg ")" 1
pass

scenario "$TAG"
echo 1 >"$SCEN/fail-list"
echo 1 >"$SCEN/fail-create"
echo 1 >"$SCEN/fail-publish"
publish 0 "failed lookups, a failed create and a failed publish are each retried" "$TAG"
expect_eq "releases" "$(release_jq 'length')" 1
expect_eq "draft" "$(release_jq '.[0].draft')" false
pass

NIGHTLY=v0.13.1-nightly.20261004
scenario "$NIGHTLY"
publish 0 "a nightly is a prerelease and never Latest" "$NIGHTLY"
expect_eq "prerelease" "$(release_jq '.[0].prerelease')" true
expect_eq "make_latest" "$(release_jq '.[0].make_latest')" false
pass

scenario "$TAG"
: >"$SCEN/tags"
publish 1 "a tag that was never pushed stops the publish before any release exists" "$TAG"
expect_eq "releases" "$(release_jq 'length')" 0
pass

scenario "$TAG"
rm "$DIST/localvoxtral-speechd-$TAG.dSYM.zip"
publish 1 "a missing asset stops the publish before any call" "$TAG"
contains "missing or empty asset"
[[ ! -s "$SCEN/calls" ]] || fail "$DESCRIPTION: gh was called"
pass

scenario "$TAG"
echo "tampered" >>"$DIST/localvoxtral-$TAG.dmg"
publish 1 "a DMG that does not match its checksum file stops the publish before any call" "$TAG"
contains "localvoxtral-$TAG.dmg.sha256 records"
[[ ! -s "$SCEN/calls" ]] || fail "$DESCRIPTION: gh was called"
pass

scenario "$TAG"
publish 2 "a malformed tag is a usage error" 'v1.0.0"; halt'
pass

# release.sh publish <tag>: downloads the failed run's artifact and reruns
# publish-release.sh on it, then pins the tap.
scenario "$TAG"
mkdir -p "$SCEN/artifact"
cp "$DIST/"* "$SCEN/artifact/"
echo always >"$SCEN/fail-upload-localvoxtral-$TAG.zip"
publish 1 "seed a draft that lacks the zip, as run 37128200212 left v0.12.0" "$TAG"
rm "$SCEN/fail-upload-localvoxtral-$TAG.zip"
cat >"$SCEN/artifacts.json" <<JSON
{"artifacts":[
  {"name":"localvoxtral-release-$TAG","expired":true,"workflow_run":{"id":111}},
  {"name":"localvoxtral-release-$TAG","expired":false,"workflow_run":{"id":222}}]}
JSON
: >"$SCEN/calls"
DESCRIPTION="release.sh publish finishes the draft from the run's artifact and pins the tap"
OUTPUT="$(SCEN="$SCEN" PUBLISH_RETRY_DELAY=0 LV_RELEASE_PUBLISH_DIR="$SCEN/download" \
  GITHUB_REPOSITORY="$REPO" PATH="$TMP_DIR/bin:$PATH" "$RELEASE" publish "$TAG" 2>&1)" \
  || fail "$DESCRIPTION: exited non-zero. Output: $OUTPUT"
grep -qxF "run download 222 -n localvoxtral-release-$TAG -D $SCEN/download" "$SCEN/calls" \
  || fail "$DESCRIPTION: did not download the unexpired artifact. Calls: $(cat "$SCEN/calls")"
expect_eq "draft" "$(release_jq '.[0].draft')" false
expect_eq "assets" "$(release_jq '.[0].assets | length')" 7
grep -qxF "workflow run cask.yml -f tag=$TAG" "$SCEN/calls" \
  || fail "$DESCRIPTION: the tap was not pinned. Calls: $(cat "$SCEN/calls")"
[[ ! -e "$SCEN/download" ]] || fail "$DESCRIPTION: the download was left behind"
pass

: >"$SCEN/calls"
DESCRIPTION="release.sh publish refuses a tag with no unexpired artifact"
echo '{"artifacts":[]}' >"$SCEN/artifacts.json"
rc=0
OUTPUT="$(SCEN="$SCEN" LV_RELEASE_PUBLISH_DIR="$SCEN/download" GITHUB_REPOSITORY="$REPO" \
  PATH="$TMP_DIR/bin:$PATH" "$RELEASE" publish "$TAG" 2>&1)" || rc=$?
expect_eq "exit" "$rc" 1
contains "No unexpired localvoxtral-release-$TAG artifact"
expect_eq "downloads" "$(calls_matching "run download")" 0
pass

DESCRIPTION="release.sh publish without a tag is a usage error"
rc=0
OUTPUT="$("$RELEASE" publish 2>&1)" || rc=$?
expect_eq "exit" "$rc" 1
contains "Usage:"
pass
