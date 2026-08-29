#!/usr/bin/env bash
set -euo pipefail

# Install a localvoxtral .app into the UI gate's artifact root, so
# `ssh lv-ui 'launch ...'` can start it.
#
#   scripts/mac/install-ui-artifact.sh <bundle.app> [--label <text>] [--no-hint]
#
# The gate (scripts/mac/localvoxtral-ui-gate.sh) refuses to launch anything
# outside LV_UI_ARTIFACT_ROOTS, and those roots are deliberately owner-writable
# only — a world-writable root would let any local process plant a bundle
# carrying com.localvoxtral.app and have the gate launch it. So the fix for
# "try-pr.sh extracts into /tmp, which the gate cannot launch" is to COPY the
# bundle into the root, never to widen the root. This script is that copy.
#
# Called by `scripts/try-pr.sh <target> --ui-gate`; also usable by hand on a
# locally packaged bundle (`dist/localvoxtral.app` from package_app.sh).
#
# Diagnostics go to stderr; the single line on stdout is the installed bundle
# path, so callers can do: APP="$(install-ui-artifact.sh "$src")".

DEST_ROOT="${LV_UI_ARTIFACT_DEST_ROOT:-$HOME/localvoxtral-ui-artifacts}"

say() { printf '%s\n' "$*" >&2; }
die() { printf 'install-ui-artifact: %s\n' "$*" >&2; exit 1; }

SOURCE=""
LABEL=""
HINT=1
while (( $# > 0 )); do
  case "$1" in
    --label)
      shift
      [[ $# -gt 0 ]] || die "--label needs a value"
      LABEL="$1"
      ;;
    # try-pr.sh prints the launch command itself, at the end, after the
    # signing output — one hint, where it is still on screen.
    --no-hint) HINT=0 ;;
    -*) die "unknown flag: $1" ;;
    *)
      [[ -z "$SOURCE" ]] || die "takes exactly one bundle"
      SOURCE="$1"
      ;;
  esac
  shift
done
[[ -n "$SOURCE" ]] || die "usage: $0 <bundle.app> [--label <text>] [--no-hint]"

# --- read the source bundle ------------------------------------------------

# Same reader as the gate's, and for the same reason: PlistBuddy when it
# exists, an XML fallback so this is exercisable off a Mac.
plist_value() { # <plist> <key>
  local plist="$1" key="$2" value
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)" || value=""
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi
  awk -v want="$key" '
    /<key>/ { k = $0; sub(/^.*<key>/, "", k); sub(/<\/key>.*$/, "", k); next }
    k == want {
      line = $0
      if (line ~ /<true\/>/) { print "true"; exit }
      if (line ~ /<false\/>/) { print "false"; exit }
      if (line ~ /<string>/) {
        sub(/^.*<string>/, "", line); sub(/<\/string>.*$/, "", line)
        print line; exit
      }
    }
  ' "$plist" 2>/dev/null
}

[[ -d "$SOURCE" ]] || die "no such bundle: $SOURCE"
SOURCE="$(cd "$SOURCE" && pwd -P)"
[[ "$SOURCE" == *.app ]] || die "not a .app bundle: $SOURCE"
PLIST="$SOURCE/Contents/Info.plist"
[[ -f "$PLIST" ]] || die "bundle has no Info.plist: $SOURCE"

# The gate applies exactly this check before launching; failing it here means
# a bundle that would be installed and then refused. Better to say so now.
[[ "$(plist_value "$PLIST" CFBundleIdentifier)" == "com.localvoxtral.app" ]] \
  || die "not a localvoxtral bundle (CFBundleIdentifier is not com.localvoxtral.app): $SOURCE"
[[ "$(plist_value "$PLIST" CFBundleExecutable)" == "localvoxtral" ]] \
  || die "bundle's CFBundleExecutable is not 'localvoxtral': $SOURCE"
[[ -x "$SOURCE/Contents/MacOS/localvoxtral" ]] \
  || die "bundle has no executable at Contents/MacOS/localvoxtral: $SOURCE"

STAMP="$(plist_value "$PLIST" LVXDogfoodCapture)"
# Two slots, not one per build: the dogfood and clean bundles differ in kind
# (the gate's `launch --dogfood` demands the stamp), but N historical copies of
# the same app would be indistinguishable at runtime — same bundle id, same
# defaults domain, same TCC grant — and launching a stale one is precisely the
# wrong-binary confusion docs/agent/field-debugging.md was written about. So a
# reinstall REPLACES its slot, and the .source file next to it records what it
# actually is.
if [[ "$STAMP" == "true" ]]; then
  NAME="localvoxtral-dogfood.app"
  VARIANT_KEY="dogfood"
  VARIANT="dogfood (LVXDogfoodCapture stamped)"
else
  NAME="localvoxtral.app"
  VARIANT_KEY="clean"
  VARIANT="clean (no LVXDogfoodCapture stamp)"
fi

# --- the destination root must stay owner-writable only --------------------

world_writable() { # <dir> -> 0 when group- or other-writable
  # BSD stat first (the Mac), GNU stat second (this also runs in CI's
  # shell-test step, which is where the refusal is actually proved).
  # Two attempts, each validated on its own: GNU stat's `-f` means
  # --file-system and prints a whole block before failing, so an `a || b`
  # substitution would capture that block AND the octal mode together.
  local dir="$1" mode="" bits=0
  mode="$(stat -f '%Lp' "$dir" 2>/dev/null || true)"
  [[ "$mode" =~ ^[0-7]+$ ]] || mode="$(stat -c '%a' "$dir" 2>/dev/null || true)"
  # A mode that cannot be read must not answer "safe": fail closed.
  [[ "$mode" =~ ^[0-7]+$ ]] || return 0
  bits=$(( 8#$mode ))
  (( (bits & 0022) != 0 ))
}

if [[ -e "$DEST_ROOT" ]]; then
  [[ -d "$DEST_ROOT" ]] || die "artifact root exists but is not a directory: $DEST_ROOT"
  # Not paranoia about this script: the gate launches anything under the root
  # that claims com.localvoxtral.app, so a root other users can write to is a
  # local-process foothold into the owner's GUI session. Refuse to feed one.
  if world_writable "$DEST_ROOT"; then
    die "artifact root is group/other-writable, which would let any local process plant a bundle the gate will launch: $DEST_ROOT (fix: chmod go-w)"
  fi
else
  mkdir -p "$DEST_ROOT" || die "cannot create artifact root: $DEST_ROOT"
  chmod 0700 "$DEST_ROOT" 2>/dev/null || true
fi
DEST_ROOT="$(cd "$DEST_ROOT" && pwd -P)"
[[ -w "$DEST_ROOT" ]] || die "artifact root is not writable: $DEST_ROOT"

DEST="$DEST_ROOT/$NAME"

# --- never overwrite a bundle that is executing ----------------------------
#
# Quitting the owner's app is NOT this script's job — the gate has a `quit`
# verb and the operator is the one who knows whether a dictation is in flight.
# What an installer must not do is replace files out from under a running
# process, so the one running instance it refuses to work around is the one
# living at the destination.
if command -v pgrep >/dev/null 2>&1; then
  RUNNING_HERE="$(pgrep -f "^$DEST/Contents/MacOS/localvoxtral" 2>/dev/null || true)"
  if [[ -n "$RUNNING_HERE" ]]; then
    die "$DEST is running (pid $(printf '%s' "$RUNNING_HERE" | tr '\n' ' ')) — quit it first (ssh lv-ui 'quit', or the menu bar item)"
  fi
  # A localvoxtral running from anywhere else is not a reason to refuse the
  # copy, but it IS a reason the gate's launch will misbehave: two instances
  # fight over the global hotkey and over the helper ports 8471/8472.
  RUNNING_ELSEWHERE="$(pgrep -x localvoxtral 2>/dev/null || true)"
  if [[ -n "$RUNNING_ELSEWHERE" ]]; then
    say "WARNING: another localvoxtral is already running (pid $(printf '%s' "$RUNNING_ELSEWHERE" | tr '\n' ' '))."
    say "         Quit it before 'launch' — a second instance collides on the global"
    say "         hotkey and on the speechd/polishd ports 8471/8472."
  fi
fi

# --- install ---------------------------------------------------------------

STAGING="$DEST_ROOT/.incoming-$NAME.$$"
OUTGOING="$DEST_ROOT/.outgoing-$NAME.$$"
cleanup() { rm -rf "$STAGING" "$OUTGOING"; }
trap cleanup EXIT

rm -rf "$STAGING"
if command -v ditto >/dev/null 2>&1; then
  ditto "$SOURCE" "$STAGING" || die "copy failed: $SOURCE -> $STAGING"
else
  cp -R "$SOURCE" "$STAGING" || die "copy failed: $SOURCE -> $STAGING"
fi

# Swap through a rename rather than deleting first: an interrupted install
# leaves the previous bundle in place instead of no bundle at all.
if [[ -e "$DEST" ]]; then
  mv "$DEST" "$OUTGOING" || die "could not move the existing bundle aside: $DEST"
fi
mv "$STAGING" "$DEST" || die "could not move the new bundle into place: $DEST"
rm -rf "$OUTGOING"

{
  printf 'installed=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'variant=%s\n' "$VARIANT_KEY"
  printf 'source=%s\n' "$SOURCE"
  if [[ -n "$LABEL" ]]; then printf 'label=%s\n' "$LABEL"; fi
} >"$DEST.source"

# The gate resolves a relative argument against the GUI user's home, which is
# the form the README's examples use; only a root outside $HOME needs the
# absolute path.
GATE_ARG="$DEST"
case "$DEST" in
  "$HOME"/*) GATE_ARG="${DEST#"$HOME"/}" ;;
esac
GATE_FLAG=""
[[ "$VARIANT_KEY" == dogfood ]] && GATE_FLAG="--dogfood "

say "Installed $VARIANT -> $DEST"
if [[ -n "$LABEL" ]]; then say "  build: $LABEL"; fi
say "  provenance: $DEST.source"
if (( HINT )); then
  say "  gate launch: ssh lv-ui 'launch $GATE_FLAG$GATE_ARG'"
fi

printf '%s\n' "$DEST"
