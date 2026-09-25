# shellcheck shell=bash
# Sourced. Which XCTest suites build and run on Linux, for `remote-build.sh
# test`, which runs those here and sends only the rest to the Mac (#545).
#
# The Linux test modules are the `.testTarget`s Package.swift declares before
# its `#if os(macOS)` block, the same split that decides what
# scripts/core-tests-linux.sh builds; a module moved across it needs no edit
# here. Written for bash 3.2, like the rest of scripts/lib.

LV_LINUX_SUITES_ROOT="${LV_LINUX_SUITES_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# One module name per line.
lv_linux_test_modules() {
  awk '
    /^#if os\(macOS\)/ { exit }
    /\.testTarget\(/ { pending = 1 }
    pending && /name: *"/ {
      name = $0
      sub(/.*name: *"/, "", name)
      sub(/".*/, "", name)
      print name
      pending = 0
    }
  ' "$LV_LINUX_SUITES_ROOT/Package.swift"
}

# XCTestCase subclasses declared under the given test directories, one per
# line.
lv_test_classes_in() {
  local dir
  for dir in "$@"; do
    [[ -d "$dir" ]] || continue
    grep -rhoE '^(final )?class [A-Za-z_][A-Za-z0-9_]* *: *XCTestCase' "$dir" \
      | sed -E 's/^(final )?class ([A-Za-z0-9_]+).*/\2/'
  done
}

lv_linux_test_classes() {
  local module
  for module in $(lv_linux_test_modules); do
    lv_test_classes_in "$LV_LINUX_SUITES_ROOT/Tests/$module"
  done
}

lv_mac_only_test_classes() {
  local dir linux_modules
  linux_modules=" $(lv_linux_test_modules | tr '\n' ' ') "
  for dir in "$LV_LINUX_SUITES_ROOT"/Tests/*/; do
    dir="${dir%/}"
    case "$linux_modules" in *" $(basename "$dir") "*) continue ;; esac
    lv_test_classes_in "$dir"
  done
}

# Exit 0 when a --filter value selects Linux suites only: a Linux module
# name, or a Linux class with an optional "Module." prefix and "/testMethod"
# suffix. The Mac reads the value as a regex that can match anywhere in
# "Module.Class/testMethod", so a value with any other character, or one a
# Mac-only class name contains, stays on the Mac.
lv_filter_is_linux_only() {
  local filter="$1" module class rest
  [[ "$filter" =~ ^[A-Za-z0-9_./]+$ ]] || return 1
  for module in $(lv_linux_test_modules); do
    [[ "$filter" == "$module" ]] && return 0
  done
  rest="$filter"
  if [[ "$rest" == *.* ]]; then
    module="${rest%%.*}"
    lv_linux_test_modules | grep -qxF "$module" || return 1
    rest="${rest#*.}"
  fi
  class="${rest%%/*}"
  if [[ "$rest" == */* ]]; then
    [[ "${rest#*/}" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  fi
  lv_linux_test_classes | grep -qxF "$class" || return 1
  if lv_mac_only_test_classes | grep -qF "$class"; then
    return 1
  fi
  return 0
}
