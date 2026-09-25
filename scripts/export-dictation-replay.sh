#!/usr/bin/env bash
# Copies this Mac's stored dictations into a replay set for
# `./scripts/remote-build.sh eval-e2e --replay EvalRecordings/replay/<set>`.
#
# Run it on the Mac that dictated, as the user who dictated, with
# "Keep dictation audio" on in Settings -> History for a while first:
#
#   ./scripts/export-dictation-replay.sh ~/Desktop/replay-2026-10-01
#
# The set holds dictated text and audio. Keep it off shared machines, copy it
# only into the gitignored EvalRecordings/replay/ of a checkout, and delete it
# when the run is done. Nothing here uploads anything.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <output directory>" >&2
  exit 1
fi
OUT="$1"
SUPPORT="$HOME/Library/Application Support"
STORE="$SUPPORT/default.store"
AUDIO="$SUPPORT/localvoxtral/dictation-audio"
LEARNED="$SUPPORT/localvoxtral/learned-terms.json"
DOMAIN="com.localvoxtral.app"

if [[ ! -f "$STORE" ]]; then
  echo "no history store at $STORE" >&2
  exit 1
fi
if [[ ! -d "$AUDIO" ]] || [[ -z "$(ls -A "$AUDIO")" ]]; then
  echo "no recordings in $AUDIO: turn on Keep dictation audio in Settings -> History and dictate first" >&2
  exit 1
fi
if [[ -e "$OUT" ]]; then
  echo "$OUT already exists; pick a new directory" >&2
  exit 1
fi
mkdir -p "$OUT"
chmod 700 "$OUT"

# The app may be writing: .backup takes a consistent copy, WAL included. The
# target is relative so no path ever sits inside a dot-command's quotes.
(cd "$OUT" && sqlite3 "$STORE" ".backup default.store")
cp -R "$AUDIO" "$OUT/dictation-audio"
if [[ -f "$LEARNED" ]]; then
  cp "$LEARNED" "$OUT/learned-terms.json"
fi
# Names and terms live in the app's defaults; the key has dots, so read it
# whole and let plutil turn the old-style plist into JSON.
if defaults read "$DOMAIN" settings.polish_speaker_terms >/dev/null 2>&1; then
  defaults read "$DOMAIN" settings.polish_speaker_terms \
    | plutil -convert json -r -o "$OUT/speaker-terms.json" -
else
  echo '[]' >"$OUT/speaker-terms.json"
fi

recordings=$(ls "$OUT/dictation-audio" | grep -c '\.wav$' || true)
echo "Exported $recordings recordings to $OUT"
echo "Next, on the dev box: copy it to EvalRecordings/replay/<set>/ in a checkout, then"
echo "  ./scripts/remote-build.sh package"
echo "  ./scripts/remote-build.sh eval-e2e --replay EvalRecordings/replay/<set>"
