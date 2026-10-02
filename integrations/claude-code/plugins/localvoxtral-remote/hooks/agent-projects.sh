#!/bin/sh
# localvoxtral agent projects scan (#1027) — strict POSIX sh, needs git.
#
# The Mac lists a repository once a coding agent ran in it in the last 30
# days, so its polishing can spell the names the user says. On this host the
# record of where Claude Code ran is its transcripts: one folder per working
# directory under ~/.claude/projects, each holding one `<session>.jsonl` per
# session. For each folder this takes the newest top-level transcript, skips
# it when it is older than 30 days, and reads the first top-level `"cwd"` key
# from its first 100 lines. That key is the only thing read from a
# transcript: nothing else is printed, kept or sent. The folder's own name is
# never decoded back into a path, because the encoding loses `/` versus `-`.
#
# The cwd then resolves the way the hook shim names the session's project:
# the basename of the repository's main checkout (post.sh's lvx_project, so a
# worktree counts as its repository), and the origin `capture.sh repository`
# prints, run in that directory. A cwd that is gone, outside git, or without
# an origin is skipped. Two cwds with the same name (worktrees of one
# repository) keep the newest.
#
#   agent-projects.sh
#     prints the X-Lvx-Agent-Projects value on one line, or nothing:
#     `<epoch>:<name>:<repository>` entries, newest first, comma-separated,
#     at most 30 of them and 2000 bytes. The epoch is the transcript's
#     modification time.
#   agent-projects.sh refresh <cache-file> <lock-dir>
#     writes `<now>` and that value, one line each, to the cache file through
#     a tempfile and rename, then removes the lock directory. The hook shim
#     starts this detached on SessionStart when its cache is missing or six
#     hours old, because the scan takes seconds and a hook has three.
#
# Everything is silent and fail-open.
set -u
umask 077
LC_ALL=C
export LC_ALL

# Absolute, because capture.sh runs from each repository's directory.
DIR="$(cd "${0%/*}" 2>/dev/null && pwd -P)" || exit 0
MODE="${1:-}"

# The repository's main checkout basename, the same rules and code as post.sh's
# lvx_project: run in a subshell from the cwd.
lvx_project() {
  command -v git >/dev/null 2>&1 || return 0
  _lvx_git="$(git rev-parse --path-format=absolute --show-toplevel --git-dir \
    --git-common-dir 2>/dev/null)" || return 0
  set -f
  IFS='
'
  # shellcheck disable=SC2086  # one field per line is the point
  set -- $_lvx_git
  [ "$#" -eq 3 ] || return 0
  for _lvx_path in "$1" "$2" "$3"; do
    case "$_lvx_path" in /*) ;; *) return 0 ;; esac
  done
  if [ "$2" = "$3" ]; then
    _lvx_name="${1##*/}"
  elif [ "${3##*/}" = ".git" ]; then
    _lvx_main="${3%/*}"
    _lvx_name="${_lvx_main##*/}"
  else
    _lvx_name="${3##*/}"
  fi
  echo "$_lvx_name"
}

# lvx_mtime <file>: its modification time in epoch seconds. There is no POSIX
# tool for it, so this tries, in order, `date -r FILE` (GNU, busybox, macOS
# and the BSDs), BSD `stat -f %m` and GNU `stat -c %Y`, and keeps the first
# answer that is 1 to 12 digits. GNU stat reads `-f %m` as a file-system query
# on a file named `%m` and prints a report, which the digit check rejects.
lvx_mtime() {
  for _lvx_try in date-r stat-f stat-c; do
    case "$_lvx_try" in
    date-r) _lvx_m="$(date -r "$1" +%s 2>/dev/null)" ;;
    stat-f) _lvx_m="$(stat -f %m "$1" 2>/dev/null)" ;;
    stat-c) _lvx_m="$(stat -c %Y "$1" 2>/dev/null)" ;;
    esac
    case "$_lvx_m" in
    "" | *[!0-9]* | ?????????????*) ;;
    *)
      echo "$_lvx_m"
      return 0
      ;;
    esac
  done
  return 1
}

# lvx_scan: one `<epoch> <name> <repository>` line per transcript folder that
# passes, unsorted.
lvx_scan() {
  [ -n "${HOME:-}" ] || return 0
  _lvx_root="$HOME/.claude/projects"
  [ -d "$_lvx_root" ] || return 0
  _lvx_now="$(date +%s 2>/dev/null)" || return 0
  case "$_lvx_now" in "" | *[!0-9]* | ?????????????*) return 0 ;; esac
  # Absolute paths throughout: the folder names start with `-`, which ls,
  # find and awk would read as an option.
  for _lvx_dir in "$_lvx_root"/*/; do
    _lvx_dir="${_lvx_dir%/}"
    [ -d "$_lvx_dir" ] || continue
    # The newest transcript, by name from `ls -t`; a name outside the
    # session-file shape (a newline, a space) is passed over.
    _lvx_file=""
    _lvx_names="$(ls -t "$_lvx_dir" 2>/dev/null)" || continue
    _lvx_old_ifs="$IFS"
    IFS='
'
    set -f
    for _lvx_name in $_lvx_names; do
      case "$_lvx_name" in
      .* | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) continue ;;
      *.jsonl) ;;
      *) continue ;;
      esac
      [ -f "$_lvx_dir/$_lvx_name" ] || continue
      _lvx_file="$_lvx_dir/$_lvx_name"
      break
    done
    set +f
    IFS="$_lvx_old_ifs"
    [ -n "$_lvx_file" ] || continue
    _lvx_epoch="$(lvx_mtime "$_lvx_file")" || continue
    if [ "$_lvx_epoch" -le "$_lvx_now" ] && [ $((_lvx_now - _lvx_epoch)) -gt 2592000 ]; then
      continue
    fi
    # The first `"cwd":"…"` that opens an object member (after `{` or `,`):
    # an escaped `\"cwd\"` inside a message's text never matches. A value
    # holding a backslash (any JSON escape) is skipped, not decoded.
    _lvx_cwd="$(awk '
      NR > 100 { exit }
      match($0, /[{,]"cwd":"[^"]*"/) {
        print substr($0, RSTART + 8, RLENGTH - 9)
        exit
      }
    ' "$_lvx_file" 2>/dev/null)" || continue
    case "$_lvx_cwd" in /*) ;; *) continue ;; esac
    case "$_lvx_cwd" in *\\*) continue ;; esac
    [ -d "$_lvx_cwd" ] || continue
    _lvx_project="$(cd "$_lvx_cwd" 2>/dev/null && lvx_project 2>/dev/null)" || continue
    [ -n "$_lvx_project" ] || continue
    _lvx_repo="$(cd "$_lvx_cwd" 2>/dev/null && sh "$DIR/capture.sh" repository </dev/null 2>/dev/null)" || continue
    [ -n "$_lvx_repo" ] || continue
    echo "$_lvx_epoch $_lvx_project $_lvx_repo"
  done
}

# lvx_value: the header value from the scan's lines. Each field is checked
# against the Mac's shape before it is kept: epoch 1 to 12 digits; name in an
# enumerated charset, at most 64 bytes, no leading dot or dash; repository in
# letters, digits and `._-/`, at most 200 bytes. Enumerated, not ranges, for
# the reason post.sh gives: a range follows the locale's collation.
lvx_value() {
  [ -r "$DIR/capture.sh" ] || return 0
  lvx_scan 2>/dev/null | sort -r -n -k 1,1 2>/dev/null | {
    _lvx_value=""
    _lvx_seen=","
    _lvx_count=0
    while read -r _lvx_epoch _lvx_name _lvx_repo _lvx_rest; do
      [ -z "$_lvx_rest" ] || continue
      case "$_lvx_epoch" in "" | *[!0-9]* | ?????????????*) continue ;; esac
      case "$_lvx_name" in
      "" | .* | -* | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) continue ;;
      esac
      [ "${#_lvx_name}" -le 64 ] || continue
      case "$_lvx_repo" in
      "" | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-]*) continue ;;
      esac
      [ "${#_lvx_repo}" -le 200 ] || continue
      case "$_lvx_seen" in *",$_lvx_name,"*) continue ;; esac
      _lvx_seen="$_lvx_seen$_lvx_name,"
      _lvx_entry="$_lvx_epoch:$_lvx_name:$_lvx_repo"
      [ $((${#_lvx_value} + ${#_lvx_entry} + 1)) -le 2000 ] || break
      _lvx_value="${_lvx_value:+$_lvx_value,}$_lvx_entry"
      _lvx_count=$((_lvx_count + 1))
      [ "$_lvx_count" -lt 30 ] || break
    done
    [ -z "$_lvx_value" ] || echo "$_lvx_value"
  }
}

if [ "$MODE" = refresh ]; then
  CACHE="${2:-}"
  LOCK="${3:-}"
  exec </dev/null >/dev/null 2>&1
  # Only the paths post.sh hands over; the lock goes when this ends, however
  # it ends.
  case "$CACHE" in /*/agent-projects) ;; *) exit 0 ;; esac
  case "$LOCK" in "$CACHE-running") ;; *) LOCK="" ;; esac
  trap '[ -z "$LOCK" ] || rmdir "$LOCK" 2>/dev/null; rm -f "$CACHE.$$" 2>/dev/null' EXIT
  trap 'exit 0' HUP INT TERM
  [ -n "$LOCK" ] || exit 0
  NOW="$(date +%s 2>/dev/null)" || exit 0
  case "$NOW" in "" | *[!0-9]* | ?????????????*) exit 0 ;; esac
  VALUE="$(lvx_value)" || VALUE=""
  { echo "$NOW" && echo "$VALUE"; } >"$CACHE.$$" && mv -f "$CACHE.$$" "$CACHE"
  exit 0
fi

lvx_value 2>/dev/null
exit 0
