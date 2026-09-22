#!/usr/bin/env bash
# run-unit-shards.sh [--coverage] <shards> <skip-name>…
#
# The unit suite as <shards> xctest processes at once, on this Mac: the
# hosted `build-test` step's side of scripts/lib/unit-test-shards.sh, which
# `remote-build.sh test` drives over ssh. Stdout is the one complete log.
#
# --coverage builds with --enable-code-coverage and leaves the merged profile
# where `swift test --enable-code-coverage` would: <bin>/codecov/default.profdata.
# The shards cannot ask SwiftPM for coverage themselves: each such run
# deletes the codecov directory when it starts and merges it when it ends, so
# side by side they delete and overwrite one another's profiles.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
coverage=0
if [[ "${1:-}" == "--coverage" ]]; then
  coverage=1
  shift
fi
if [[ $# -lt 1 || ! "$1" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 [--coverage] <shards> <skip-name>..." >&2
  exit 64
fi
shards="$1"
shift

# shellcheck source=../lib/unit-test-shards.sh
. "$ROOT_DIR/scripts/lib/unit-test-shards.sh"

cd "$ROOT_DIR"
lv_shard_swift() {
  swift "$@"
}

codecov=""
if (( coverage == 1 )); then
  export LV_SHARD_BUILD_ARGS="--enable-code-coverage"
  codecov="$(swift build --show-bin-path)/codecov"
  rm -rf "$codecov"
  mkdir -p "$codecov"
  # The pattern SwiftPM itself sets: %p gives each process its own file, %m
  # lets one process's runs merge into it.
  export LLVM_PROFILE_FILE="$codecov/xctest%m.%p.profraw"
fi

status=0
lv_run_unit_shards "$shards" /dev/null "$@" || status=$?

if (( coverage == 1 && status == 0 )); then
  shopt -s nullglob
  profiles=("$codecov"/*.profraw)
  if (( ${#profiles[@]} == 0 )); then
    echo "==> --coverage: no profile under $codecov"
    exit 1
  fi
  xcrun llvm-profdata merge -sparse "${profiles[@]}" -o "$codecov/default.profdata"
  echo "==> Coverage: ${#profiles[@]} profiles merged into $codecov/default.profdata"
fi
exit "$status"
