#!/usr/bin/env bash
# Linux XCTest aborts the whole test process at discovery when a @MainActor
# XCTestCase class has no async test method: `--dump-tests-json` dies on
# "Could not cast value of type '(T) -> @Swift.MainActor () -> ()'" (#1859).
# One async test in the class avoids it. This check names the class before
# the core suite's build gets there.
#
# Scans every test target that builds on Linux (all of Tests/ but the app's
# localvoxtralTests). A test method belongs to the nearest top-level `class`
# or `extension` above it. The check runs on two fixtures first to show it
# fails and passes as it should.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lv-mainactor-classes.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

scan() {
  python3 - "$1" <<'PY'
import os, re, sys
root = sys.argv[1]
decl = re.compile(r'^(?:@\w+\s+)*(?:(?:public|package|internal|private|fileprivate|final)\s+)*(class|extension)\s+(\w+)\b([^{]*)')
test = re.compile(r'^\s+(?:@\w+\s+)*(?:override\s+)?func\s+(test\w*)\s*\(\)\s*(async)?')
main_actor, tests = set(), {}
for dirpath, dirnames, files in os.walk(root):
    dirnames[:] = [d for d in dirnames if d != 'localvoxtralTests']
    for name in files:
        if not name.endswith('.swift'):
            continue
        owner, attr = None, False
        for line in open(os.path.join(dirpath, name), encoding='utf-8'):
            m = decl.match(line)
            if m:
                kind, owner, rest = m.groups()
                if kind == 'class' and 'XCTestCase' in rest and (attr or '@MainActor' in line):
                    main_actor.add(owner)
                attr = False
                continue
            if line.startswith('@MainActor'):
                attr = True
            elif line.strip() and not line.startswith('@'):
                attr = False
            t = test.match(line)
            if t and owner:
                tests.setdefault(owner, []).append(bool(t.group(2)))
bad = sorted(c for c in main_actor if tests.get(c) and not any(tests[c]))
for c in bad:
    print(f"{c}: @MainActor XCTestCase with no async test method; Linux XCTest aborts at discovery. Make one test async.")
sys.exit(1 if bad else 0)
PY
}

mkdir -p "$TMP_DIR/bad" "$TMP_DIR/good"
cat >"$TMP_DIR/bad/BadTests.swift" <<'SWIFT'
@MainActor
final class BadTests: XCTestCase {
    func testOne() {}
}
SWIFT
cat >"$TMP_DIR/good/GoodTests.swift" <<'SWIFT'
@MainActor
final class GoodTests: XCTestCase {
    func testOne() {}
}

extension GoodTests {
    func testTwo() async {}
}
SWIFT

if scan "$TMP_DIR/bad" >/dev/null; then
  echo "FAIL: the check passed a @MainActor class with only sync tests" >&2
  exit 1
fi
scan "$TMP_DIR/good" || { echo "FAIL: the check refused a class with an async test" >&2; exit 1; }
echo "PASS: the check fails on an all-sync @MainActor class and passes one with an async test"

scan "$ROOT_DIR/Tests" || exit 1
echo "PASS: every @MainActor test class that builds on Linux has an async test"
