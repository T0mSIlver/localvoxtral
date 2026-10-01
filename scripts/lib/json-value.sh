# shellcheck shell=bash
# Sourced. lv_json_value KEYPATH: the string, number or bool at KEYPATH
# ("result.pane.pane_id", "result.workspaces.0.workspace_id") in the JSON on
# stdin, printed bare (a bool as true or false); non-zero exit when the input
# is not JSON or the path holds no such value.
#
# plutil, which every Mac has, reads it. python3 stands in where plutil is
# missing, so the Linux CI runs the same scripts. scripts/install.sh keeps a
# copy: it runs alone, fetched by curl.
lv_json_value() {
  if command -v plutil >/dev/null 2>&1; then
    plutil -extract "$1" raw -o - - 2>/dev/null
  else
    python3 -c '
import json, sys
try:
    value = json.load(sys.stdin)
    for key in sys.argv[1].split("."):
        value = value[int(key)] if isinstance(value, list) else value[key]
except (ValueError, KeyError, IndexError, TypeError):
    sys.exit(1)
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (str, int, float)):
    print(value)
else:
    sys.exit(1)
' "$1"
  fi
}
