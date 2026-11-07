#!/usr/bin/env bash
# Regression test for render-appcast.py, the Sparkle feed release.yml
# publishes with each stable release (LVX-57). A wrong feed reaches every
# installed copy within a day, and only a real release runs the renderer, so
# its output and its refusals are checked here.
#
# No network, no key: ./scripts/ci/test-render-appcast.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
RENDER="$ROOT_DIR/scripts/ci/render-appcast.py"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-render-appcast-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

SIG_A="$(printf 'a%.0s' {1..86})=="
SIG_B="$(printf 'b%.0s' {1..86})=="
SIG_C="$(printf 'c%.0s' {1..86})=="
DATE="Tue, 03 Nov 2026 03:15:00 +0000"

FEED="$TMP_DIR/appcast.xml"
python3 "$RENDER" --tag v0.18.0 --build 2100 --minimum-system 15.0 --pub-date "$DATE" \
  --zip "47351174:$SIG_A" --delta "2050:4393874:$SIG_B" --delta "2080:1200000:$SIG_C" >"$FEED" \
  || fail "a full release: exited non-zero"

python3 - "$FEED" "$SIG_A" "$SIG_B" "$SIG_C" <<'PY' || fail "the feed does not read back as Sparkle expects"
import sys, xml.etree.ElementTree as ET
feed, sig_a, sig_b, sig_c = sys.argv[1:]
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(feed).getroot().findall("channel/item")
assert len(items) == 1, f"{len(items)} items"
item = items[0]
assert item.findtext(f"{S}version") == "2100"
assert item.findtext(f"{S}shortVersionString") == "0.18.0"
assert item.findtext(f"{S}minimumSystemVersion") == "15.0"
zip_ = item.find("enclosure")
assert zip_.get("url") == "https://github.com/T0mSIlver/localvoxtral/releases/download/v0.18.0/localvoxtral-v0.18.0.zip", zip_.get("url")
assert zip_.get("length") == "47351174"
assert zip_.get(f"{S}edSignature") == sig_a
deltas = item.findall(f"{S}deltas/enclosure")
got = [(d.get(f"{S}deltaFrom"), d.get("url").rsplit("/", 1)[1], d.get(f"{S}edSignature")) for d in deltas]
assert got == [
    ("2080", "localvoxtral-v0.18.0-from-2080.delta", sig_c),
    ("2050", "localvoxtral-v0.18.0-from-2050.delta", sig_b),
], got
PY
pass "one item: version, build, zip and two deltas (newest base first), each with its signature"

python3 "$RENDER" --tag v0.18.0 --build 2100 --minimum-system 15.0 --pub-date "$DATE" \
  --zip "47351174:$SIG_A" >"$TMP_DIR/no-deltas.xml" || fail "no deltas: exited non-zero"
grep -q 'sparkle:deltas' "$TMP_DIR/no-deltas.xml" && fail "no deltas: printed an empty deltas block"
pass "a release with no earlier base has no deltas block"

expect_refusal() {
  local description="$1"
  shift
  if python3 "$RENDER" "$@" >"$TMP_DIR/refused.xml" 2>"$TMP_DIR/refused.err"; then
    fail "$description: expected a refusal, got exit 0"
  fi
  [[ ! -s "$TMP_DIR/refused.xml" ]] || fail "$description: a refusal must print no feed"
  pass "$description -> refused ($(head -n1 "$TMP_DIR/refused.err"))"
}
COMMON=(--build 2100 --minimum-system 15.0 --pub-date "$DATE")
expect_refusal "a nightly tag" --tag v0.18.1-nightly.20261103 "${COMMON[@]}" --zip "1:$SIG_A"
expect_refusal "an unsigned zip" --tag v0.18.0 "${COMMON[@]}" --zip "47351174:"
expect_refusal "a zero-length zip" --tag v0.18.0 "${COMMON[@]}" --zip "0:$SIG_A"
expect_refusal "a delta from the same build" --tag v0.18.0 "${COMMON[@]}" --zip "1:$SIG_A" --delta "2100:5:$SIG_B"
expect_refusal "two deltas from one build" --tag v0.18.0 "${COMMON[@]}" --zip "1:$SIG_A" \
  --delta "2050:5:$SIG_B" --delta "2050:6:$SIG_C"
