#!/usr/bin/env bash
# scripts/lib/json-value.sh and install.sh's copy of it read the same answers
# from the same JSON: with plutil on macOS (build-test), with python3 on Linux.
# The herdr documents are herdr 0.9.0's own output.
#   ./scripts/ci/test-json-value.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../lib/json-value.sh
source "$ROOT_DIR/scripts/lib/json-value.sh"
# install.sh's copy, without running the installer.
eval "$(sed -n '/^json_value() {$/,/^}$/p' "$ROOT_DIR/scripts/install.sh")"
declare -F json_value >/dev/null || { echo "FAIL: no json_value in install.sh" >&2; exit 1; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

CREATE='{"id":"cli:workspace:create","result":{"root_pane":{"agent_status":"unknown","cwd":"/home/dev","focused":true,"pane_id":"w1:p1","revision":0,"tab_id":"w1:t1","workspace_id":"w1"},"tab":{"label":"1","number":1,"tab_id":"w1:t1","workspace_id":"w1"},"type":"workspace_created","workspace":{"active_tab_id":"w1:t1","label":"~","number":1,"pane_count":1,"workspace_id":"w1"}}}'
LIST='{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[{"focused":true,"label":"glossator","workspace_id":"w59"},{"focused":false,"label":"reach","workspace_id":"w5A"}]}}'
RELEASE='{"tag_name":"v1.2.3","body":null,"draft":false,"prerelease":true,"assets":[{"label":null,"size":42,"browser_download_url":"https://example/a.zip"}]}'

# expect READER KEYPATH DOCUMENT WANT: WANT is the value, or "<none>" for a
# non-zero exit.
expect() {
  local got status
  set +e
  got="$("$1" "$2" <<<"$3")"
  status=$?
  set -e
  if [[ "$4" == "<none>" ]]; then
    (( status != 0 )) || fail "$1 $2: read '$got', want no value"
  else
    (( status == 0 )) && [[ "$got" == "$4" ]] || fail "$1 $2: read '$got' (exit $status), want '$4'"
  fi
}

for reader in lv_json_value json_value; do
  expect "$reader" result.root_pane.pane_id "$CREATE" "w1:p1"
  expect "$reader" result.workspace.workspace_id "$CREATE" "w1"
  expect "$reader" result.type "$LIST" "workspace_list"
  expect "$reader" result.workspaces.1.workspace_id "$LIST" "w5A"
  expect "$reader" result.workspaces.2.workspace_id "$LIST" "<none>"
  expect "$reader" result.pane.pane_id "$LIST" "<none>"
  expect "$reader" tag_name "$RELEASE" "v1.2.3"
  expect "$reader" draft "$RELEASE" "false"
  expect "$reader" prerelease "$RELEASE" "true"
  expect "$reader" assets.0.size "$RELEASE" "42"
  expect "$reader" assets.0.browser_download_url "$RELEASE" "https://example/a.zip"
  expect "$reader" tag_name 'Warning: Permanently added host' "<none>"
  printf 'PASS: %s reads herdr and GitHub documents\n' "$reader"
done
