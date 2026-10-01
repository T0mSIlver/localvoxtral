#!/bin/sh
# localvoxtral doctor, remote host side (#910). Read-only checks of this
# host's end of the dictation tunnel, then the Mac's own checks through it.
# Strict POSIX sh: it runs under bash 3.2's sh on a macOS host.
#
#   doctor.sh [--json]
#
# The remote Claude Code plugin puts it on the agent's PATH as
# `localvoxtral doctor` (bin/localvoxtral); the Vibe remote hooks install it
# as ~/.vibe/localvoxtral/remote/doctor.sh.
#
# It checks: which port the Mac's RemoteForward should bind here and whether
# anything answers there; that the listener refuses a request without the
# token (401) and takes one with it (200); the Claude Code plugin installed
# against the version each running session loaded; the Vibe hooks; the last
# hook's outcome. The token is never printed and never in an argv: it reaches
# curl through a 0600 header file, as in post.sh.
#
# Exit status: 0 when nothing failed, 4 when a check failed, as on the Mac.
set -u
umask 077

DOCTOR_VERSION=1.32.0
JSON=0
case "${1:-}" in
--json) JSON=1 ;;
"") ;;
-h | --help)
  echo "usage: localvoxtral doctor [--json]"
  echo "Checks this host's end of the localvoxtral tunnel, then the Mac's checks through it."
  exit 0
  ;;
*)
  echo "localvoxtral: on a remote host only \`localvoxtral doctor\` runs; the other commands run on the Mac." >&2
  exit 2
  ;;
esac

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
VIBE_REMOTE="${HOME:-}/.vibe/localvoxtral/remote"
PLUGIN_KEY="localvoxtral-remote@localvoxtral"
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  STAMP_DIR="$XDG_RUNTIME_DIR/localvoxtral"
else
  STAMP_DIR="${HOME:-}/.cache/localvoxtral"
fi

WORK="$(mktemp -d 2>/dev/null)" || {
  echo "localvoxtral: could not create a private temporary directory" >&2
  exit 1
}
trap 'rm -rf "$WORK"' EXIT
trap 'rm -rf "$WORK"; exit 1' HUP INT TERM

# --- Output --------------------------------------------------------------------
# Each check is one record in $WORK/checks: id, state, title, detail, fix,
# separated by a unit separator.
US="$(printf '\037')"
FAILED=0
WARNED=0
check() {
  case "$2" in
  failed) FAILED=$((FAILED + 1)) ;;
  warning) WARNED=$((WARNED + 1)) ;;
  esac
  printf '%s%s%s%s%s%s%s%s%s\n' "$1" "$US" "$2" "$US" "$3" "$US" "$4" "$US" "${5:-}" >>"$WORK/checks"
}

json_string() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g')"
}

# First JSON string value of "key" after "anchor" in a file, or nothing. One
# awk pass over the whole file, so a pretty-printed file and a one-line one
# read the same. Values with an escaped quote are not ours and read as
# nothing.
json_value_after() {
  [ -r "$1" ] || return 0
  LC_ALL=C awk -v anchor="\"$2\"" -v key="\"$3\"" '
    { text = text $0 "\n" }
    END {
      start = index(text, anchor)
      if (start == 0) exit
      rest = substr(text, start + length(anchor))
      at = index(rest, key)
      if (at == 0) exit
      rest = substr(rest, at + length(key))
      if (match(rest, /^[[:space:]]*:[[:space:]]*"[^"\\]*"/)) {
        value = substr(rest, RSTART, RLENGTH)
        sub(/^[[:space:]]*:[[:space:]]*"/, "", value)
        sub(/"$/, "", value)
        print value
      }
    }
  ' "$1" 2>/dev/null
}

age_text() {
  _now="$(date +%s 2>/dev/null)" || _now=""
  case "$1$_now" in *[!0-9]* | "") echo "at an unknown time" && return ;; esac
  _age=$((_now - $1))
  if [ "$_age" -lt 60 ]; then echo "$_age s ago"
  elif [ "$_age" -lt 3600 ]; then echo "$((_age / 60)) min ago"
  elif [ "$_age" -lt 172800 ]; then echo "$((_age / 3600)) h ago"
  else echo "$((_age / 86400)) days ago"
  fi
}

# --- Where the tunnel should be ------------------------------------------------
PORT=""
PORT_FROM=""
if [ -n "${CLAUDE_PLUGIN_OPTION_PORT:-}" ]; then
  PORT="$CLAUDE_PLUGIN_OPTION_PORT"
  PORT_FROM="the plugin's hook environment"
fi
if [ -z "$PORT" ]; then
  PORT="$(json_value_after "$CLAUDE_DIR/settings.json" "$PLUGIN_KEY" port)"
  [ -z "$PORT" ] || PORT_FROM="$CLAUDE_DIR/settings.json"
fi
if [ -z "$PORT" ] && [ -r "$VIBE_REMOTE/port" ]; then
  IFS= read -r PORT <"$VIBE_REMOTE/port" 2>/dev/null || PORT=""
  [ -z "$PORT" ] || PORT_FROM="$VIBE_REMOTE/port"
fi
case "$PORT" in
"" | *[!0-9]* | 0* | ??????*)
  PORT=8473
  PORT_FROM="the default (no port configured)"
  ;;
esac

TOKEN=""
TOKEN_FROM=""
if [ -n "${CLAUDE_PLUGIN_OPTION_TOKEN:-}" ]; then
  TOKEN="$CLAUDE_PLUGIN_OPTION_TOKEN"
  TOKEN_FROM="the plugin's hook environment"
fi
if [ -z "$TOKEN" ]; then
  TOKEN="$(json_value_after "$CLAUDE_DIR/.credentials.json" "$PLUGIN_KEY" token)"
  [ -z "$TOKEN" ] || TOKEN_FROM="$CLAUDE_DIR/.credentials.json"
fi
if [ -z "$TOKEN" ] && [ -r "$VIBE_REMOTE/token" ]; then
  IFS= read -r TOKEN <"$VIBE_REMOTE/token" 2>/dev/null || TOKEN=""
  [ -z "$TOKEN" ] || TOKEN_FROM="$VIBE_REMOTE/token"
fi
case "$TOKEN" in
*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~+/=-]*) TOKEN="" ;;
esac

# --- The listener, without and with the token ----------------------------------
# curl's exit status tells the two dead ends apart: 7 is nothing listening on
# this port (no ssh session holds the forward), 52 is the forward up but no app
# answering behind it on the Mac.
URL="http://127.0.0.1:$PORT/v1/doctor"
MAC_BODY=""
MAC_FAILED=""
if ! command -v curl >/dev/null 2>&1; then
  check tunnel failed "Tunnel" "curl is not installed, and the hooks need it." \
    "Install curl on this host."
else
  CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -X POST -H 'Content-Length: 0' "$URL" 2>/dev/null)"
  CURL_EXIT=$?
  if [ "$CURL_EXIT" -eq 7 ]; then
    check tunnel failed "Tunnel" "Nothing listens on 127.0.0.1:$PORT (port from $PORT_FROM)." \
      "No ssh session from the Mac holds the forward. On the Mac: Settings > Remote hosts > Keep the tunnel open, or open an ssh session to this host from the Mac's terminal."
  elif [ "$CURL_EXIT" -eq 52 ] || [ "$CURL_EXIT" -eq 56 ]; then
    check tunnel failed "Tunnel" "Port $PORT is forwarded, but nothing answers behind it on the Mac." \
      "Open localvoxtral on the Mac. If it is running, its remote listener failed; the reason is in Settings > Remote hosts."
  elif [ "$CODE" = "401" ]; then
    check tunnel ok "Tunnel" "127.0.0.1:$PORT reaches localvoxtral (port from $PORT_FROM)."
  else
    check tunnel failed "Tunnel" "127.0.0.1:$PORT answered HTTP $CODE (curl exit $CURL_EXIT), not localvoxtral's 401." \
      "Another program holds port $PORT on this host, or the Mac's forward points elsewhere. On the Mac: Settings > Remote hosts > Update Host…"
  fi

  if [ "$CODE" = "401" ]; then
    if [ -z "$TOKEN" ]; then
      check token failed "Token" "No token found: not in the hook environment, $CLAUDE_DIR/.credentials.json or $VIBE_REMOTE/token." \
        "On the Mac: Settings > Remote hosts > Update Host… installs it again. On a macOS host, Claude Code keeps it in the Keychain, where this check cannot read it."
    else
      # A heredoc through cat, never printf: the token must not reach an argv.
      cat >"$WORK/header" <<EOF
Authorization: Bearer $TOKEN
EOF
      if [ "$JSON" = 1 ]; then
        cat >>"$WORK/header" <<'EOF'
Accept: application/json
EOF
      fi
      CODE="$(curl -sS -o "$WORK/mac" -D "$WORK/mac-head" -w '%{http_code}' --max-time 12 -X POST \
        -H 'Content-Length: 0' --header "@$WORK/header" "$URL" 2>/dev/null)" || CODE="000"
      case "$CODE" in
      200)
        check token ok "Token" "Accepted (from $TOKEN_FROM)."
        MAC_BODY="$WORK/mac"
        # The Mac's count of failed checks, from its reply header; empty
        # from a Mac older than the header (remote plugin 1.27.0).
        MAC_FAILED="$(LC_ALL=C awk -F': *' 'tolower($1) == "x-lvx-doctor-failed" {
          sub(/\r$/, "", $2); if ($2 ~ /^[0-9]+$/) n = $2 } END { print n }' "$WORK/mac-head" 2>/dev/null)"
        ;;
      401)
        check token failed "Token" "Refused (from $TOKEN_FROM): revoked, rotated, or another Mac's." \
          "On the Mac: Settings > Remote hosts > Update Host… installs this host's current token."
        ;;
      404)
        check token ok "Token" "Accepted (from $TOKEN_FROM)."
        check mac warning "Mac" "The app on the Mac is older than this script and has no doctor route." \
          "Update localvoxtral on the Mac, then run \`localvoxtral doctor\` there."
        ;;
      *)
        check token warning "Token" "The Mac answered HTTP $CODE." \
          "Run it again; if it repeats, run \`localvoxtral doctor\` on the Mac."
        ;;
      esac
    fi
  fi
fi

# --- The Claude Code plugin ----------------------------------------------------
# is_session PID FILE: PID runs and is the process Claude Code wrote FILE for.
# FILE records the process start time (field 22 of /proc/<pid>/stat), so a
# pid reused since then is another process. Without /proc (macOS) the pid
# must at least run a command named claude.
is_session() {
  kill -0 "$1" 2>/dev/null || return 1
  if [ -r "/proc/$1/stat" ]; then
    _want="$(sed -n 's/.*"procStart"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*/\1/p' "$2" 2>/dev/null)"
    _have="$(awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat" 2>/dev/null)"
    [ -z "$_want" ] || [ "$_want" = "$_have" ]
    return
  fi
  case "$(ps -p "$1" -o command= 2>/dev/null)" in *claude*) return 0 ;; esac
  return 1
}

INSTALLED="$(json_value_after "$CLAUDE_DIR/plugins/installed_plugins.json" "$PLUGIN_KEY" version)"
CACHE="$CLAUDE_DIR/plugins/cache/localvoxtral/localvoxtral-remote"
if [ -z "$INSTALLED" ]; then
  check claude-plugin skipped "Claude Code plugin" "Not installed on this host."
elif LC_ALL=C grep -q "\"$PLUGIN_KEY\"[[:space:]]*:[[:space:]]*false" "$CLAUDE_DIR/settings.json" 2>/dev/null; then
  check claude-plugin failed "Claude Code plugin" "$INSTALLED is installed but turned off in $CLAUDE_DIR/settings.json." \
    "Run \`claude plugin enable $PLUGIN_KEY\`, then \`/reload-plugins\` in each Claude Code session."
else
  # Running sessions and the plugin version each loaded, by pid. Claude Code
  # used to leave a session's pid under `.in_use` in the cache directory of
  # each version it loaded; one that ran `/reload-plugins` can keep a marker
  # under the version it started with too, so a pid with a marker under the
  # installed version is current. Claude Code 2.1.280 to 2.1.286 write none
  # (#1159): the live sessions then come from Claude Code's own
  # sessions/<pid>.json, and each one's version from the record the plugin's
  # hook keeps under its session id (post.sh). A session with neither runs a
  # plugin older than 1.31.0, or none.
  OLD=""
  UNKNOWN=""
  CURRENT=" "
  SEEN=" "
  LIVE=0
  for marker in "$CACHE"/*/.in_use/*; do
    [ -f "$marker" ] || continue
    pid="${marker##*/}"
    case "$pid" in "" | *[!0-9]*) continue ;; esac
    is_session "$pid" "$marker" || continue
    case "$SEEN" in *" $pid "*) ;; *) SEEN="$SEEN$pid " LIVE=$((LIVE + 1)) ;; esac
    version="${marker%/.in_use/*}"
    version="${version##*/}"
    if [ "$version" = "$INSTALLED" ]; then
      CURRENT="$CURRENT$pid "
    else
      OLD="$OLD $version:$pid"
    fi
  done
  for record in "$CLAUDE_DIR"/sessions/*.json; do
    [ -f "$record" ] || continue
    pid="${record##*/}"
    pid="${pid%.json}"
    case "$pid" in "" | *[!0-9]*) continue ;; esac
    is_session "$pid" "$record" || continue
    case "$SEEN" in *" $pid "*) ;; *) SEEN="$SEEN$pid " LIVE=$((LIVE + 1)) ;; esac
    sid="$(sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9-]*\)".*/\1/p' "$record" 2>/dev/null | head -n 1)"
    version=""
    [ -z "$sid" ] || { IFS= read -r version <"$STAMP_DIR/plugin-version/$sid"; } 2>/dev/null || :
    case "$version" in *[!0-9.]*) version="" ;; esac
    if [ "$version" = "$INSTALLED" ]; then
      CURRENT="$CURRENT$pid "
    elif [ -n "$version" ]; then
      case "$OLD " in *" $version:$pid "*) ;; *) OLD="$OLD $version:$pid" ;; esac
    else
      UNKNOWN="$UNKNOWN $pid"
    fi
  done
  STALE=""
  for entry in $OLD; do
    case "$CURRENT" in *" ${entry##*:} "*) ;; *) STALE="$STALE $entry" ;; esac
  done
  NONE=""
  for pid in $UNKNOWN; do
    case "$CURRENT$OLD " in *" $pid "* | *":$pid "*) ;; *) NONE="$NONE $pid" ;; esac
  done
  if [ -n "$STALE$NONE" ]; then
    DETAIL="$INSTALLED installed"
    [ -z "$STALE" ] || DETAIL="$DETAIL; running sessions still on older versions (version:pid):$STALE"
    [ -z "$NONE" ] || DETAIL="$DETAIL; running sessions with no plugin version recorded (pid):$NONE"
    check claude-plugin warning "Claude Code plugin" "$DETAIL." \
      "Run \`/reload-plugins\` in those Claude Code sessions: a session keeps the hooks it loaded, and one older than 1.31.0 records no version."
  else
    check claude-plugin ok "Claude Code plugin" "$INSTALLED installed; $LIVE running session(s), none on an older version."
  fi
fi

# --- The Vibe hooks ------------------------------------------------------------
if [ -r "$VIBE_REMOTE/post.sh" ]; then
  VIBE_VERSION="$(sed -n 's/^X-Lvx-Vibe-Hooks-Version: \([0-9.]*\)$/\1/p' "$VIBE_REMOTE/post.sh" 2>/dev/null | head -n 1)"
  if LC_ALL=C grep -q '^# >>> localvoxtral remote >>>' "${HOME:-}/.vibe/hooks.toml" 2>/dev/null; then
    check vibe-hooks ok "Mistral Vibe hooks" "${VIBE_VERSION:-An unknown version} installed and listed in ~/.vibe/hooks.toml."
  else
    check vibe-hooks warning "Mistral Vibe hooks" "${VIBE_VERSION:-An unknown version} installed, not listed in ~/.vibe/hooks.toml." \
      "On the Mac: Settings > Remote hosts > Update Host…"
  fi
else
  check vibe-hooks skipped "Mistral Vibe hooks" "Not installed on this host."
fi

# --- The last hook ---------------------------------------------------------------
STATUS=""
[ -r "$STAMP_DIR/hook-status" ] && IFS= read -r STATUS <"$STAMP_DIR/hook-status" 2>/dev/null
STATE="${STATUS%% *}"
WHEN="${STATUS#* }"
case "$STATE" in
"") check last-hook skipped "Last Claude Code hook" "None recorded in $STAMP_DIR." ;;
ok) check last-hook ok "Last Claude Code hook" "Delivered $(age_text "$WHEN")." ;;
down) check last-hook warning "Last Claude Code hook" "Could not reach the Mac $(age_text "$WHEN")." \
  "See the Tunnel check above." ;;
unconfigured) check last-hook warning "Last Claude Code hook" "Had no token $(age_text "$WHEN")." \
  "On the Mac: Settings > Remote hosts > Update Host…, then restart Claude Code sessions." ;;
http-*) check last-hook warning "Last Claude Code hook" "The Mac answered ${STATE#http-} $(age_text "$WHEN")." \
  "See the Token check above." ;;
*) check last-hook skipped "Last Claude Code hook" "Unreadable stamp in $STAMP_DIR." ;;
esac

# --- Print ---------------------------------------------------------------------
if [ "$JSON" = 1 ]; then
  printf '{"cli":1,"ok":true,"host":{"doctor":"%s","checks":[' "$DOCTOR_VERSION"
  first=1
  while IFS="$US" read -r id state title detail fix; do
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"id":%s,"state":%s,"title":%s,"detail":%s' "$(json_string "$id")" "$(json_string "$state")" \
      "$(json_string "$title")" "$(json_string "$detail")"
    [ -z "$fix" ] || printf ',"fix":%s' "$(json_string "$fix")"
    printf '}'
  done <"$WORK/checks"
  printf ']},"mac":'
  if [ -n "$MAC_BODY" ] && [ -s "$MAC_BODY" ]; then
    tr -d '\n' <"$MAC_BODY"
  else
    printf 'null'
  fi
  printf '}\n'
else
  echo "This host:"
  n=0
  while IFS="$US" read -r id state title detail fix; do
    n=$((n + 1))
    case "$state" in
    ok) mark="ok  " ;;
    warning) mark="warn" ;;
    failed) mark="FAIL" ;;
    *) mark="--  " ;;
    esac
    echo "$n. [$mark] $title: $detail"
    [ -z "$fix" ] || [ "$state" = ok ] || echo "   fix: $fix"
  done <"$WORK/checks"
  if [ "$FAILED" -eq 0 ] && [ "$WARNED" -eq 0 ]; then
    echo "No problems found here."
  else
    echo "$FAILED failed, $WARNED to look at here."
  fi
  if [ -n "$MAC_BODY" ] && [ -s "$MAC_BODY" ]; then
    echo ""
    echo "The Mac:"
    cat "$MAC_BODY"
  fi
fi

if [ "$FAILED" -gt 0 ]; then exit 4; fi
if [ -n "$MAC_FAILED" ]; then
  [ "$MAC_FAILED" -eq 0 ] || exit 4
# A Mac without the header: read its report. Remove once no Mac older than
# remote plugin 1.27.0 answers.
elif [ -n "$MAC_BODY" ] && LC_ALL=C grep -q '\[FAIL\]\|"state":"failed"' "$MAC_BODY" 2>/dev/null; then
  exit 4
fi
exit 0
