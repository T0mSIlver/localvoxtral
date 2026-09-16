#!/usr/bin/env bash
# Regression test for install.sh release-asset resolution (issue #131).
#
# v0.7.4 started shipping dSYM archives next to the app zip, and the GitHub
# API listed them first, so "take the first .zip asset" resolved the
# debug-symbol archive and the install failed at extraction. The fix selects
# the asset by its exact contractual name (localvoxtral-<tag>.zip, the name
# release.yml has produced for every release), so no ordering and no future
# extra zip asset can ever be picked by mistake. This test runs install.sh in
# dry-run mode against a stubbed curl serving hostile fixtures and asserts
# the app zip always wins — or that resolution fails loudly.
#
# Pure bash, no network, runs anywhere: ./scripts/ci/test-install-resolve.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-install-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Stub curl: writes the fixture named by LV_TEST_FIXTURE to the -o target,
# records the requested URL in LV_TEST_URL_LOG (which endpoint the installer
# asks for is half of the channel contract), and prints the HTTP code
# install.sh expects from -w '%{http_code}'.
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 1
[ -z "${LV_TEST_URL_LOG:-}" ] || printf '%s\n' "$url" >> "$LV_TEST_URL_LOG"
cat "$LV_TEST_FIXTURE" > "$out"
printf '200'
STUB
chmod +x "$TMP_DIR/bin/curl"

run_resolve() {
  local fixture="$1" version="$2" channel="${3:-stable}"
  : > "$TMP_DIR/urls.txt"
  PATH="$TMP_DIR/bin:$PATH" LV_TEST_FIXTURE="$fixture" \
    LV_TEST_URL_LOG="$TMP_DIR/urls.txt" \
    LOCALVOXTRAL_INSTALL_DRYRUN=1 LOCALVOXTRAL_VERSION="$version" \
    LOCALVOXTRAL_CHANNEL="$channel" \
    bash "$ROOT_DIR/scripts/install.sh"
}

requested_url() { sed -n '1p' "$TMP_DIR/urls.txt"; }

expected="https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.zip"

# Case 1: hostile asset ordering. Mirrors the real v0.7.4 API response (dSYM
# zip listed before the app zip, which triggered #131), plus the polishd dSYM
# zip release.yml attaches to newer releases, plus a hypothetical future
# non-dSYM zip listed first — the case a dSYM-only blocklist would get wrong.
cat > "$TMP_DIR/release.json" <<'JSON'
{
  "tag_name": "v0.7.4",
  "assets": [
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4-update.zip"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.dmg"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.dmg.sha256"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.dSYM.zip"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-polishd-v0.7.4.dSYM.zip"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.zip"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.zip.sha256"}
  ]
}
JSON

output="$(run_resolve "$TMP_DIR/release.json" v0.7.4)" || fail "install.sh dry run exited non-zero:
$output"
resolved="$(printf '%s\n' "$output" | sed -n 's/^Resolved zip: //p')"
[ "$resolved" = "$expected" ] ||
  fail "resolved '$resolved', expected '$expected'"
echo "PASS: exact app zip wins over dSYM zips and other zip assets"

# Case 2: a release without the contractual app zip must die loudly, not
# fall back to whatever zip is present (here: only a dSYM archive).
cat > "$TMP_DIR/release-dsym-only.json" <<'JSON'
{
  "tag_name": "v0.7.4",
  "assets": [
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.7.4/localvoxtral-v0.7.4.dSYM.zip"}
  ]
}
JSON

if output="$(run_resolve "$TMP_DIR/release-dsym-only.json" v0.7.4 2>&1)"; then
  fail "expected failure when the app zip asset is missing, got:
$output"
fi
case "$output" in
  *"has no asset named localvoxtral-v0.7.4.zip"*) ;;
  *) fail "expected 'has no asset named' error, got:
$output" ;;
esac
echo "PASS: release without the app zip fails with a clear error"

# Case 3: VERSION=latest — the expected asset name must come from the
# metadata's tag_name, not from LOCALVOXTRAL_VERSION.
output="$(run_resolve "$TMP_DIR/release.json" latest)" || fail "install.sh dry run (latest) exited non-zero:
$output"
resolved="$(printf '%s\n' "$output" | sed -n 's/^Resolved zip: //p')"
[ "$resolved" = "$expected" ] ||
  fail "latest resolved '$resolved', expected '$expected'"
echo "PASS: VERSION=latest resolves via the metadata tag_name"

# ---------------------------------------------------------------------------
# The nightly channel (LOCALVOXTRAL_CHANNEL=nightly).
#
# Nightlies are prereleases, so GitHub's /releases/latest never returns one
# and the nightly path reads the release LIST instead. Two things must hold:
# the installer asks the right endpoint per channel, and the selector picks
# the newest NIGHTLY out of a list that also holds stable releases, rc
# prereleases and (for an authenticated caller) drafts.
# ---------------------------------------------------------------------------

release_url="https://github.com/T0mSIlver/localvoxtral/releases/download"

# Ordered newest first, exactly as the API returns it. The first two entries
# are the traps: a draft nightly (never published, must be ignored) and an rc
# prerelease that a naive "first prerelease" selector would take.
cat > "$TMP_DIR/releases-list.json" <<'JSON'
[
  {
    "tag_name": "v0.8.5-nightly.20260918",
    "draft": true,
    "prerelease": true,
    "assets": [
      {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.8.5-nightly.20260918/localvoxtral-v0.8.5-nightly.20260918.zip"}
    ],
    "body": "unpublished draft"
  },
  {
    "tag_name": "v0.9.0-rc.1",
    "draft": false,
    "prerelease": true,
    "assets": [
      {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.9.0-rc.1/localvoxtral-v0.9.0-rc.1.zip"}
    ],
    "body": "release candidate"
  },
  {
    "tag_name": "v0.8.4",
    "draft": false,
    "prerelease": false,
    "assets": [
      {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.8.4/localvoxtral-v0.8.4.zip"}
    ],
    "body": "stable"
  },
  {
    "tag_name": "v0.8.5-nightly.20260917.2",
    "draft": false,
    "prerelease": true,
    "assets": [
      {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.8.5-nightly.20260917.2/localvoxtral-v0.8.5-nightly.20260917.2.dSYM.zip"},
      {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.8.5-nightly.20260917.2/localvoxtral-v0.8.5-nightly.20260917.2.zip"},
      {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.8.5-nightly.20260917.2/localvoxtral-v0.8.5-nightly.20260917.2.zip.sha256"}
    ],
    "body": "nightly build of main"
  },
  {
    "tag_name": "v0.8.5-nightly.20260916",
    "draft": false,
    "prerelease": true,
    "assets": [
      {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.8.5-nightly.20260916/localvoxtral-v0.8.5-nightly.20260916.zip"}
    ],
    "body": "nightly build of main"
  }
]
JSON

expected_nightly="$release_url/v0.8.5-nightly.20260917.2/localvoxtral-v0.8.5-nightly.20260917.2.zip"
output="$(run_resolve "$TMP_DIR/releases-list.json" latest nightly)" ||
  fail "nightly dry run exited non-zero:
$output"
resolved="$(printf '%s\n' "$output" | sed -n 's/^Resolved zip: //p')"
[ "$resolved" = "$expected_nightly" ] ||
  fail "nightly resolved '$resolved', expected '$expected_nightly'"
case "$(requested_url)" in
  *"/releases?per_page=30") ;;
  *) fail "nightly should read the releases list, asked for: $(requested_url)" ;;
esac
echo "PASS: nightly picks the newest nightly, ignoring stable, rc and draft releases"

# The stable channel must never land on a nightly. Its guarantee is the
# endpoint: /releases/latest is documented to exclude prereleases, and every
# nightly is one.
cat > "$TMP_DIR/release-stable.json" <<'JSON'
{
  "tag_name": "v0.8.4",
  "draft": false,
  "prerelease": false,
  "assets": [
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.8.4/localvoxtral-v0.8.4.zip"}
  ]
}
JSON

output="$(run_resolve "$TMP_DIR/release-stable.json" latest)" ||
  fail "stable dry run exited non-zero:
$output"
resolved="$(printf '%s\n' "$output" | sed -n 's/^Resolved zip: //p')"
[ "$resolved" = "$release_url/v0.8.4/localvoxtral-v0.8.4.zip" ] ||
  fail "stable resolved '$resolved'"
case "$(requested_url)" in
  *"/releases/latest") ;;
  *) fail "stable should read /releases/latest (which excludes prereleases), asked for: $(requested_url)" ;;
esac
echo "PASS: stable reads /releases/latest and never sees a nightly"

# An explicit nightly tag: LOCALVOXTRAL_VERSION wins over the channel and
# goes straight to that tag's metadata.
cat > "$TMP_DIR/release-nightly-tag.json" <<'JSON'
{
  "tag_name": "v0.8.5-nightly.20260916",
  "draft": false,
  "prerelease": true,
  "assets": [
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.8.5-nightly.20260916/localvoxtral-v0.8.5-nightly.20260916.dSYM.zip"},
    {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.8.5-nightly.20260916/localvoxtral-v0.8.5-nightly.20260916.zip"}
  ]
}
JSON

expected_pinned="$release_url/v0.8.5-nightly.20260916/localvoxtral-v0.8.5-nightly.20260916.zip"
for channel in stable nightly; do
  output="$(run_resolve "$TMP_DIR/release-nightly-tag.json" v0.8.5-nightly.20260916 "$channel")" ||
    fail "explicit nightly tag ($channel) exited non-zero:
$output"
  resolved="$(printf '%s\n' "$output" | sed -n 's/^Resolved zip: //p')"
  [ "$resolved" = "$expected_pinned" ] ||
    fail "explicit nightly tag ($channel) resolved '$resolved', expected '$expected_pinned'"
  case "$(requested_url)" in
    *"/releases/tags/v0.8.5-nightly.20260916") ;;
    *) fail "explicit tag should read the tags endpoint, asked for: $(requested_url)" ;;
  esac
done
echo "PASS: LOCALVOXTRAL_VERSION pins a nightly tag on either channel"

# A repo with no nightly yet must say so instead of installing a stable build
# behind the user's back.
cat > "$TMP_DIR/releases-no-nightly.json" <<'JSON'
[
  {"tag_name": "v0.8.4", "draft": false, "prerelease": false, "assets": []},
  {"tag_name": "v0.9.0-rc.1", "draft": false, "prerelease": true, "assets": []}
]
JSON

if output="$(run_resolve "$TMP_DIR/releases-no-nightly.json" latest nightly 2>&1)"; then
  fail "expected failure when no nightly exists, got:
$output"
fi
case "$output" in
  *"No nightly release found"*) ;;
  *) fail "expected a 'no nightly release found' error, got:
$output" ;;
esac
echo "PASS: no nightly in the list fails with a clear error"

# Release bodies carry generated notes, i.e. contributor-written PR titles. A
# body that embeds release-shaped JSON must not be able to redirect the
# download: the asset is still selected by exact name AND by the tag's own
# download prefix, so the worst a crafted body can do is make the install
# fail loudly.
cat > "$TMP_DIR/releases-hostile-body.json" <<'JSON'
[
  {
    "tag_name": "v0.8.5-nightly.20260917",
    "draft": false,
    "prerelease": true,
    "assets": [
      {"browser_download_url": "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.8.5-nightly.20260917/localvoxtral-v0.8.5-nightly.20260917.zip"}
    ],
    "body": "merged PR: fix \"tag_name\": \"v0.8.5-nightly.20261299\", \"draft\": false, \"prerelease\": true and https://evil.example/localvoxtral-v0.8.5-nightly.20261299.zip"
  }
]
JSON

output="$(run_resolve "$TMP_DIR/releases-hostile-body.json" latest nightly 2>&1)" || true
case "$output" in
  *evil.example*) fail "a release body redirected the download:
$output" ;;
esac
echo "PASS: a hostile release body cannot redirect the resolved zip"

echo "OK: all install.sh resolution tests passed"
