#!/usr/bin/env bash
# The Sparkle update feed for one stable release (LVX-57), run by release.yml
# on the Mini after notarization.
#
#   build-update-feed.sh feed <tag> <dist-dir>
#       Signs dist/localvoxtral-<tag>.zip, builds a delta from each of the last
#       three releases kept in the base dir, signs those, and writes
#       dist/appcast.xml (render-appcast.py). Refuses when the new app does
#       not satisfy the release team's requirement, or an older release's own
#       designated requirement: an app that fails the second would lose its
#       macOS permissions on update, and Sparkle would refuse it anyway.
#   build-update-feed.sh keep <dist-dir>
#       After the publish: keeps dist/localvoxtral.app in the base dir, named
#       by its build number, so the next releases can diff against it. Keeps
#       the newest three.
#
# LV_UPDATE_KEY_FILE  the EdDSA private key (default
#                     ~/.config/localvoxtral-release/sparkle-ed25519.key, mode
#                     600, the Mini's release account only; its public half is
#                     SUPublicEDKey in package_app.sh)
# LV_UPDATE_BASE_DIR  the kept releases (default
#                     ~/Library/Application Support/localvoxtral-release/update-bases)
# SPARKLE_BIN         Sparkle's tools (default: the SwiftPM artifact under .build)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
KEY_FILE="${LV_UPDATE_KEY_FILE:-$HOME/.config/localvoxtral-release/sparkle-ed25519.key}"
BASE_DIR="${LV_UPDATE_BASE_DIR:-$HOME/Library/Application Support/localvoxtral-release/update-bases}"
KEEP=3
# AppUpdatePolicy.releaseTeamRequirement says the same.
TEAM_REQUIREMENT='anchor apple generic and certificate leaf[subject.OU] = "3N63N7U9R3"'

die() { echo "build-update-feed.sh: $*" >&2; exit 1; }

sparkle_bin() {
  if [[ -n "${SPARKLE_BIN:-}" ]]; then
    echo "$SPARKLE_BIN"
    return
  fi
  local tool
  tool="$(find "$ROOT_DIR/.build/artifacts" -type f -path '*/Sparkle/bin/sign_update' 2>/dev/null | head -n 1)"
  [[ -n "$tool" ]] || die "no Sparkle tools under .build/artifacts; build the app first, or set SPARKLE_BIN"
  dirname "$tool"
}

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }

# sign <file>: prints "<length>:<signature>".
sign() {
  local out signature length
  out="$("$BIN/sign_update" --ed-key-file "$KEY_FILE" "$1")"
  signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$out")"
  length="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$out")"
  [[ -n "$signature" && -n "$length" ]] || die "sign_update printed no signature for $1: $out"
  echo "$length:$signature"
}

# Build numbers of the kept releases, newest first.
kept_builds() {
  [[ -d "$BASE_DIR" ]] || return 0
  find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | grep -E '^[0-9]+$' | sort -rn || true
}

feed() {
  local tag="$1" dist="$2"
  local app="$dist/localvoxtral.app" zip="$dist/localvoxtral-$tag.zip"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "only a stable vX.Y.Z release gets a feed: $tag"
  [[ -d "$app" && -s "$zip" ]] || die "no $app or $zip"
  [[ -s "$KEY_FILE" ]] || die "no update signing key at $KEY_FILE"
  BIN="$(sparkle_bin)"

  codesign --verify -R="$TEAM_REQUIREMENT" "$app" \
    || die "$app is not signed by the release team; an update feed must never offer it"
  local build minimum
  build="$(plist "$app" CFBundleVersion)"
  minimum="$(plist "$app" LSMinimumSystemVersion)"
  echo "Feed for $tag (build $build, macOS $minimum+)"

  local args=(--tag "$tag" --build "$build" --minimum-system "$minimum"
    --pub-date "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
    --zip "$(sign "$zip")")
  local count=0 base old requirement delta
  while IFS= read -r base; do
    [[ -n "$base" ]] || continue
    (( base < build )) || continue
    (( count < KEEP )) || break
    old="$BASE_DIR/$base/localvoxtral.app"
    requirement="$(codesign -d -r- "$old" 2>&1 | sed -n 's/^designated => //p')"
    [[ -n "$requirement" ]] || die "build $base in $BASE_DIR has no designated requirement"
    codesign --verify -R="$requirement" "$app" \
      || die "$tag does not satisfy build $base's designated requirement ($requirement): updating would drop its permissions"
    delta="$dist/localvoxtral-$tag-from-$base.delta"
    rm -f "$delta"
    "$BIN/BinaryDelta" create "$old" "$app" "$delta"
    args+=(--delta "$base:$(sign "$delta")")
    echo "  delta from build $base: $(wc -c <"$delta" | tr -d ' ') bytes"
    count=$((count + 1))
  done < <(kept_builds)
  (( count > 0 )) || echo "  no earlier release kept in $BASE_DIR: full download only"

  python3 "$ROOT_DIR/scripts/ci/render-appcast.py" "${args[@]}" >"$dist/appcast.xml"
  echo "Wrote $dist/appcast.xml"
}

keep() {
  local dist="$1" app="$1/localvoxtral.app" build
  [[ -d "$app" ]] || die "no $app"
  build="$(plist "$app" CFBundleVersion)"
  mkdir -p "$BASE_DIR"
  rm -rf "${BASE_DIR:?}/$build"
  mkdir -p "$BASE_DIR/$build"
  ditto "$app" "$BASE_DIR/$build/localvoxtral.app"
  local index=0
  while IFS= read -r base; do
    [[ -n "$base" ]] || continue
    index=$((index + 1))
    if (( index > KEEP )); then
      rm -rf "${BASE_DIR:?}/$base"
      echo "Dropped build $base from $BASE_DIR"
    fi
  done < <(kept_builds)
  echo "Kept build $build in $BASE_DIR"
}

case "${1:-}" in
  feed) [[ $# -eq 3 ]] || die "usage: $0 feed <tag> <dist-dir>"; feed "$2" "$3" ;;
  keep) [[ $# -eq 2 ]] || die "usage: $0 keep <dist-dir>"; keep "$2" ;;
  *) die "usage: $0 feed <tag> <dist-dir> | keep <dist-dir>" ;;
esac
