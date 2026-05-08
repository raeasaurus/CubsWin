#!/usr/bin/env bash
# scripts/_lib.sh — shared security primitives for the CubsWin agent.
#
# Sourced by every helper script (cubs.sh, espn.sh, sports.sh,
# build-catalog.sh). Centralises:
#
#   - input validators           (valid_team_name, valid_id, ...)
#   - hardened HTTP fetcher      (safe_curl)
#   - atomic, mode-0600 state    (atomic_write)
#   - cooperative tick mutex     (with_lock)
#   - catalog integrity check    (assert_catalog_sane)
#
# Threat model in plain English:
#   1. We treat command-line args, env vars, and API responses as
#      untrusted. The catalog file is trusted but is range-checked on
#      load so a corrupted/tampered catalog can't escalate.
#   2. Every URL we fetch is pinned to an allow-list of hostnames over
#      HTTPS only, with size + redirect caps so a hostile or compromised
#      upstream can't exhaust memory or pivot to another host.
#   3. Every state write is atomic (temp + rename, mode 0600) so a
#      crash mid-tick can't leave parsers reading partial JSON, and a
#      mutex prevents racing ticks from clobbering each other.
#   4. State paths and catalog ids are pre-validated so nothing
#      attacker-influenced can flow into shell, jq paths, or curl URLs.
#
# Loading idiom (after the script's own `set -euo pipefail`):
#
#       LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#       # shellcheck source=scripts/_lib.sh
#       . "$LIB_DIR/_lib.sh"

# ---- input validators -------------------------------------------------------
#
# Each validator is a strict allow-list (success = exit 0). They are written
# narrowly: a real Cubs/Bears name fits, but anything containing a shell
# metacharacter, NUL, control char, or path separator does not.

# Team names: 1-40 chars, must contain at least one alphanumeric (so a
# lone "; ;" can't slip past on the strength of being short and printable).
valid_team_name() {
  [[ "$1" =~ ^[A-Za-z0-9.\ -]{1,40}$ && "$1" =~ [A-Za-z0-9] ]]
}

# Highlight headline filters: same character set as team names but allow
# empty (the no-filter case). Used by jq --arg, never reaches curl URLs.
valid_filter() {
  [[ "$1" =~ ^[A-Za-z0-9.\ -]{0,40}$ ]]
}

# Numeric ids (MLB teamId, ESPN teamId, gamePk). Up to 12 digits covers
# every observed real id (the largest NHL expansion id today is 6 digits).
valid_id() {
  [[ "$1" =~ ^[0-9]{1,12}$ ]]
}

# ESPN event ids — numeric in practice, but the API is undocumented so we
# accept letters/dot/dash/underscore as a safety margin. Hard-capped at
# 40 chars so a malicious upstream can't smuggle a long URL fragment.
valid_event_id() {
  [[ "$1" =~ ^[A-Za-z0-9._-]{1,40}$ ]]
}

# League keys: hard whitelist. Anything else is a programmer error and
# should fail loudly.
valid_league() {
  case "$1" in mlb|nfl|nba|nhl) return 0 ;; *) return 1 ;; esac
}

# State-file paths must be project-relative (no absolute paths, no `..`
# segments). Defends against `STATE_FILE=/etc/passwd` style overrides.
valid_state_path() {
  case "$1" in /*|*..*) return 1 ;; *) return 0 ;; esac
}

# ---- hardened HTTP fetcher --------------------------------------------------
#
# Every outbound HTTP call goes through safe_curl. The function refuses any
# URL whose hostname isn't on the allow-list, forces HTTPS, caps redirects
# and response size, and times out fast. Output is the response body or
# nothing (and a non-zero exit code) on failure — no curl errors leak to
# stderr, since the callers already report meaningful "no game today"
# messages on their own.

CUBSWIN_ALLOWED_HOSTS=(
  "statsapi.mlb.com"
  "site.api.espn.com"
)

# Extract the hostname from an https://host[:port]/path URL.
url_host() {
  local u="$1"
  case "$u" in
    https://*) ;;
    *) return 1 ;;
  esac
  local rest="${u#https://}"
  rest="${rest%%/*}"
  rest="${rest%%:*}"
  printf '%s' "$rest"
}

safe_curl() {
  local url="$1"
  local host
  host="$(url_host "$url")" || return 1

  # Hostname allow-list. Defends against catalog tampering or future code
  # paths that build URLs from data we don't fully trust.
  local ok=0 h
  for h in "${CUBSWIN_ALLOWED_HOSTS[@]}"; do
    [[ "$host" == "$h" ]] && { ok=1; break; }
  done
  if (( ok == 0 )); then
    echo "safe_curl: refused non-allowlisted host: $host" >&2
    return 1
  fi

  # --proto =https     : refuse plaintext or any non-HTTPS redirect target
  # --tlsv1.2          : reject anything older than TLS 1.2
  # --max-redirs 3     : caps redirect chains; defends against open-redirect-
  #                      style pivots if the upstream is compromised
  # --max-filesize 5M  : prevents OOM if a hostile/buggy upstream returns
  #                      gigabytes of JSON
  # --connect-timeout 5: fast fail; keeps the loop responsive
  # --max-time 10      : total request cap; preserves Phase-1 behaviour
  # -fsL               : -f fail on HTTP errors, -s silent body, -L follow
  #                      (limited) redirects
  curl \
    --proto '=https' \
    --tlsv1.2 \
    --max-redirs 3 \
    --max-filesize 5242880 \
    --connect-timeout 5 \
    --max-time 10 \
    -fsL \
    "$url" \
    2>/dev/null
}

# ---- atomic state writes ----------------------------------------------------
#
# Writing JSON via `> "$STATE_FILE"` is non-atomic: a crash mid-write leaves
# a half-written file that crashes the next tick under `set -e`. We write
# to a sibling tmp file with mode 0600, then rename(2) it into place. The
# rename is atomic on POSIX, so concurrent readers either see the old file
# or the new one — never a torn write.

atomic_write() {
  local target="$1" content="$2"
  local dir; dir="$(dirname "$target")"
  mkdir -p "$dir"
  local tmp; tmp="$(mktemp "$dir/.cubswin.XXXXXX")"
  # Restrictive perms: state files contain game ids, last-play indices,
  # and other arguably-private telemetry. 0600 keeps them owner-only.
  chmod 600 "$tmp"
  printf '%s\n' "$content" > "$tmp"
  mv -f "$tmp" "$target"
}

# ---- cooperative mutex ------------------------------------------------------
#
# /loop 3m /sports-update can in theory tick while a previous tick is still
# running (slow network, stalled jq). Without a mutex, the two ticks read
# and write the same state file and lose updates. with_lock serialises ticks
# at the tick-helper boundary; the outer orchestrator doesn't lock, so
# different teams can still tick in parallel inside one /sports-update call.
#
# Uses flock(1) when available (Linux), falls back to mkdir-based locking
# elsewhere (macOS without coreutils, BusyBox).

with_lock() {
  local lockfile="$1"; shift
  mkdir -p "$(dirname "$lockfile")"
  if command -v flock >/dev/null 2>&1; then
    # 200 is an arbitrary but unused fd. Non-blocking (-n) so a stuck
    # tick can't permanently wedge the loop; a stale lock just causes
    # this tick to skip (silent, like any other no-op tick).
    (
      flock -n 200 || exit 0
      "$@"
    ) 200>"$lockfile"
  else
    local lockdir="${lockfile}.d"
    if mkdir "$lockdir" 2>/dev/null; then
      # shellcheck disable=SC2064  # we want $lockdir captured at trap time
      trap "rmdir '$lockdir' 2>/dev/null" EXIT
      "$@"
      rmdir "$lockdir" 2>/dev/null
      trap - EXIT
    fi
  fi
}

# ---- catalog integrity ------------------------------------------------------
#
# The catalog ships in-tree but build-catalog.sh can rewrite it from live
# APIs. Validate basic shape on load so a corrupted regenerated catalog
# can't sneak non-integer ids, oversized strings, or shell-meta names into
# the resolver.

assert_catalog_sane() {
  local file="$1"
  jq -e '
    # Each league must be an array with reasonable length, and every
    # entry must have an integer id and a string name no longer than 80
    # chars. aliases is optional but if present must be a string array.
    (.mlb // []) as $mlb | (.nfl // []) as $nfl |
    (.nba // []) as $nba | (.nhl // []) as $nhl |
    [$mlb, $nfl, $nba, $nhl] as $all |
    ($all | all(type == "array")) and
    ($all | all(length >= 25 and length <= 60)) and
    ($all | all(all(
      (.id | type == "number") and (.id >= 1) and (.id <= 1000000000) and
      (.name | type == "string") and (.name | length <= 80) and
      ((.aliases // []) | type == "array") and
      ((.aliases // []) | all(type == "string" and length <= 40))
    )))
  ' "$file" >/dev/null
}
